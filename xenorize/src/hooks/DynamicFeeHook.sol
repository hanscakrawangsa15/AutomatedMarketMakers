// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {FeeState, Xenorize__ZeroAddress, Xenorize__Unauthorized, Xenorize__EmergencyPaused, Xenorize__TimelockNotElapsed} from "../types/XenorizeTypes.sol";
import {IXenorizeOracle, AggregatorV3Interface} from "../interfaces/IXenorize.sol";

contract XenorizeDynamicFeeHook {

    address public immutable poolManager;
    address public immutable owner;
    address public immutable feeRecipient;

    IXenorizeOracle        public oracle;
    AggregatorV3Interface  public ethUsdFeed;

    mapping(bytes32 => FeeState) public poolFeeState;
    mapping(bytes32 => uint256)  public poolTVLUSD;
    mapping(bytes32 => uint256)  public pendingChanges;

    uint24  public baseFee         = 30;
    uint256 public targetVolBps    = 3_000;
    uint256 public oracleMaxAge    = 1 hours;
    uint256 public mevThresholdBps = 50;
    bool    public paused;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    event FeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee);
    event MEVDetected(bytes32 indexed poolId, address indexed swapper, uint256 premiumBps);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ParameterQueued(bytes32 indexed paramHash, uint256 executeTime);
    event EmergencyPause(bool paused);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }
    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert Xenorize__Unauthorized(msg.sender, poolManager);
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert Xenorize__EmergencyPaused();
        _;
    }

    constructor(
        address _poolManager, address _owner, address _feeRecipient,
        address _oracle, address _ethUsdFeed
    ) {
        if (_poolManager == address(0) || _owner == address(0) || _feeRecipient == address(0))
            revert Xenorize__ZeroAddress();
        poolManager  = _poolManager;
        owner        = _owner;
        feeRecipient = _feeRecipient;
        oracle       = IXenorizeOracle(_oracle);
        ethUsdFeed   = AggregatorV3Interface(_ethUsdFeed);
    }

    function getHookPermissions() external pure returns (uint256) {
        return (1 << 7) | (1 << 6); // beforeSwap + afterSwap
    }

    function beforeSwap(
        bytes32 poolId, address swapper, uint256 swapAmountUSD
    ) external onlyPoolManager whenNotPaused returns (uint24 lpFeeOverride) {
        uint256 vol         = _getVolatility(poolId);
        bool    mevDetected = _detectMEV(poolId, swapAmountUSD);

        lpFeeOverride = XenorizeMath.computeDynamicFee(
            baseFee, vol, targetVolBps, swapAmountUSD, poolTVLUSD[poolId], mevDetected
        );

        FeeState storage fs = poolFeeState[poolId];
        uint24 old = fs.currentDynamicFee;
        fs.currentDynamicFee = lpFeeOverride;
        fs.volatilityIndex   = vol;
        fs.lastFeeUpdate     = block.timestamp;
        fs.mevPremium        = mevDetected ? 50 : 0;

        if (lpFeeOverride != old) emit FeeUpdated(poolId, old, lpFeeOverride);
        if (mevDetected)          emit MEVDetected(poolId, swapper, 50);
    }

    function afterSwap(bytes32 poolId) external onlyPoolManager whenNotPaused {
        poolId; // Phase 2: route MEV fee to insurance fund
    }

    function _getVolatility(bytes32 poolId) internal view returns (uint256) {
        if (address(oracle) != address(0)) {
            try oracle.getVolatility(poolId) returns (uint256 v) {
                if (v > 0) return v;
            } catch {}
        }
        return targetVolBps;
    }

    function _detectMEV(bytes32 poolId, uint256 swapAmountUSD) internal view returns (bool) {
        if (poolTVLUSD[poolId] == 0) return false;
        uint256 ratio = (swapAmountUSD * XenorizeMath.BPS_MAX) / poolTVLUSD[poolId];
        return ratio > mevThresholdBps * 10;
    }

    function queueOracleUpdate(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert Xenorize__ZeroAddress();
        bytes32 h = keccak256(abi.encode("oracle", newOracle));
        pendingChanges[h] = block.timestamp + TIMELOCK_DELAY;
        emit ParameterQueued(h, pendingChanges[h]);
    }

    function executeOracleUpdate(address newOracle) external onlyOwner {
        bytes32 h = keccak256(abi.encode("oracle", newOracle));
        uint256 t = pendingChanges[h];
        if (t == 0 || block.timestamp < t)
            revert Xenorize__TimelockNotElapsed(t, block.timestamp);
        delete pendingChanges[h];
        address old = address(oracle);
        oracle = IXenorizeOracle(newOracle);
        emit OracleUpdated(old, newOracle);
    }

    function updatePoolTVL(bytes32 poolId, uint256 tvlUSD) external {
        poolTVLUSD[poolId] = tvlUSD;
    }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }

    function getCurrentFee(bytes32 poolId) external view returns (uint24) {
        return poolFeeState[poolId].currentDynamicFee;
    }

    function previewFee(
        bytes32 poolId, uint256 swapAmountUSD, bool mevDetected
    ) external view returns (uint24) {
        return XenorizeMath.computeDynamicFee(
            baseFee, _getVolatility(poolId), targetVolBps,
            swapAmountUSD, poolTVLUSD[poolId], mevDetected
        );
    }
}
