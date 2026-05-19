// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Uniswap V4 ───────────────────────────────────────────────────
import {IHooks}          from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta}    from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks}           from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary}    from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency}        from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ─── Xenorize ─────────────────────────────────────────────────────
import {XenorizeMath}    from "../libraries/XenorizeMath.sol";
import {FeeState, Xenorize__ZeroAddress, Xenorize__Unauthorized, Xenorize__EmergencyPaused, Xenorize__TimelockNotElapsed} from "../types/XenorizeTypes.sol";
import {IXenorizeOracle, IInsuranceFund, AggregatorV3Interface} from "../interfaces/IXenorize.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title XenorizeDynamicFeeHook
/// @notice Uniswap V4 hook that provides dynamic fees based on volatility, swap size, and MEV detection.
///         Also routes MEV premiums to the IL Insurance Fund.
/// @dev Must be deployed at an address whose lower bits match Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
///      Use HookMiner or CREATE2 salt mining before deployment.
contract XenorizeDynamicFeeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ─── Constants ───────────────────────────────────────────────
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant BPS_MAX        = 10_000;

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager   public immutable poolManager;
    address        public immutable owner;
    address        public immutable feeRecipient;
    IInsuranceFund public immutable insuranceFund;

    // ─── Storage ──────────────────────────────────────────────────
    IXenorizeOracle       public oracle;
    AggregatorV3Interface public ethUsdFeed;

    mapping(PoolId => FeeState) public poolFeeState;
    mapping(PoolId => uint256)  public poolTVLUSD;
    mapping(bytes32 => uint256) public pendingChanges;
    // Transient-style MEV flag (cleared in afterSwap, same tx)
    mapping(PoolId => bool)     private _mevFlag;

    uint24  public baseFee         = 30;
    uint256 public targetVolBps    = 3_000;
    uint256 public oracleMaxAge    = 1 hours;
    uint256 public mevThresholdBps = 50;
    bool    public paused;

    // ─── Events ───────────────────────────────────────────────────
    event FeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee);
    event MEVDetected(PoolId indexed poolId, address indexed swapper, uint256 premiumBps);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ParameterQueued(bytes32 indexed paramHash, uint256 executeTime);
    event EmergencyPause(bool paused);
    event MEVFeeRouted(PoolId indexed poolId, uint256 amount);

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Xenorize__Unauthorized(msg.sender, address(poolManager));
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert Xenorize__EmergencyPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────
    constructor(
        IPoolManager _poolManager,
        address      _owner,
        address      _feeRecipient,
        address      _insuranceFund,
        address      _oracle,
        address      _ethUsdFeed
    ) {
        if (address(_poolManager) == address(0) || _owner == address(0) || _feeRecipient == address(0))
            revert Xenorize__ZeroAddress();
        poolManager   = _poolManager;
        owner         = _owner;
        feeRecipient  = _feeRecipient;
        insuranceFund = IInsuranceFund(_insuranceFund);
        oracle        = IXenorizeOracle(_oracle);
        ethUsdFeed    = AggregatorV3Interface(_ethUsdFeed);

        // Note: Hooks.validateHookPermissions is NOT called in the constructor
        // because it requires a CREATE2-mined address (bits 7+6 set exactly).
        // Call validateHookAddress() after deployment to verify the address is correct.
        // In production, use HookMiner + CREATE2 to deploy at the right address.
    }

    /// @notice Returns true when this contract is deployed at an address whose lower
    ///         14 bits match exactly BEFORE_SWAP | AFTER_SWAP (= 0x00C0).
    ///         Call this after deployment to verify V4 hook address correctness.
    function validateHookAddress() external view returns (bool) {
        uint160 addr  = uint160(address(this));
        uint160 mask  = (1 << 14) - 1;   // all 14 hook-permission bits
        uint160 flags = (1 << 7) | (1 << 6); // BEFORE_SWAP | AFTER_SWAP
        return addr & mask == flags;
    }

    // ─── Hook Permissions ─────────────────────────────────────────

    /// @notice Declares which V4 hooks this contract implements.
    ///         BEFORE_SWAP + AFTER_SWAP → address bits 7 and 6 must be set.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:              false,
            afterInitialize:               false,
            beforeAddLiquidity:            false,
            afterAddLiquidity:             false,
            beforeRemoveLiquidity:         false,
            afterRemoveLiquidity:          false,
            beforeSwap:                    true,
            afterSwap:                     true,
            beforeDonate:                  false,
            afterDonate:                   false,
            beforeSwapReturnDelta:         false,
            afterSwapReturnDelta:          false,
            afterAddLiquidityReturnDelta:  false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── V4 Hook Implementations ──────────────────────────────────

    /// @notice Called by PoolManager before every swap.
    ///         Returns a dynamic fee override (requires pool to have DYNAMIC_FEE_FLAG).
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager whenNotPaused returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        uint256 vol         = _getVolatility(poolId);
        uint256 swapSizeUSD = _estimateSwapUSD(key, params);
        bool    mevDetected = _detectMEV(poolId, swapSizeUSD);

        uint24 dynamicFee = XenorizeMath.computeDynamicFee(
            baseFee, vol, targetVolBps, swapSizeUSD, poolTVLUSD[poolId], mevDetected
        );

        // Set fee override flag required by V4 (bit 23 = OVERRIDE_FEE_FLAG)
        uint24 lpFeeOverride = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        // Update stored state
        FeeState storage fs = poolFeeState[poolId];
        uint24 old = fs.currentDynamicFee;
        fs.currentDynamicFee = dynamicFee;
        fs.volatilityIndex   = vol;
        fs.lastFeeUpdate     = block.timestamp;
        fs.mevPremium        = mevDetected ? 50 : 0;

        if (dynamicFee != old) emit FeeUpdated(poolId, old, dynamicFee);

        if (mevDetected) {
            _mevFlag[poolId] = true;
            emit MEVDetected(poolId, sender, 50);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /// @notice Called by PoolManager after every swap.
    ///         Routes MEV premium to InsuranceFund if MEV was detected.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager whenNotPaused returns (bytes4, int128) {
        PoolId poolId = key.toId();

        if (_mevFlag[poolId]) {
            _mevFlag[poolId] = false;

            // Route MEV fee (50 BPS of unspecified token delta) to insurance fund.
            // Only routes if the pool's currency1 matches the fund's primary asset.
            int128 unspecified = delta.amount1();
            if (unspecified < 0 && address(insuranceFund) != address(0)) {
                uint256 mevFee = (uint256(uint128(-unspecified)) * 50) / BPS_MAX;
                address token1 = Currency.unwrap(key.currency1);
                if (mevFee > 0 && token1 == insuranceFund.asset()) {
                    try poolManager.take(key.currency1, address(this), mevFee) {
                        IERC20(token1).approve(address(insuranceFund), mevFee);
                        insuranceFund.depositFee(mevFee);
                        emit MEVFeeRouted(poolId, mevFee);
                    } catch {}
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Unimplemented IHooks stubs ───────────────────────────────
    // These revert if accidentally called — PoolManager only calls
    // hooks whose permission bits are set in the address.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert();
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert();
    }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert(); }

    // ─── Internal helpers ─────────────────────────────────────────

    function _getVolatility(PoolId poolId) internal view returns (uint256) {
        if (address(oracle) != address(0)) {
            try oracle.getVolatility(PoolId.unwrap(poolId)) returns (uint256 v) {
                if (v > 0) return v;
            } catch {}
        }
        return targetVolBps;
    }

    function _detectMEV(PoolId poolId, uint256 swapSizeUSD) internal view returns (bool) {
        if (poolTVLUSD[poolId] == 0) return false;
        uint256 ratio = (swapSizeUSD * BPS_MAX) / poolTVLUSD[poolId];
        return ratio > mevThresholdBps * 10;
    }

    /// @notice Estimate USD value of swap from params.amountSpecified using oracle price.
    function _estimateSwapUSD(PoolKey calldata key, SwapParams calldata params)
        internal view returns (uint256)
    {
        int256 amt = params.amountSpecified;
        uint256 absAmt = amt < 0 ? uint256(-amt) : uint256(amt);
        if (address(oracle) == address(0)) return absAmt;
        address token = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        try oracle.getTokenPriceUSD(token) returns (uint256 price, uint256) {
            return (absAmt * price) / 1e18;
        } catch {}
        return absAmt;
    }

    // ─── Admin ────────────────────────────────────────────────────

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

    function updatePoolTVL(PoolId poolId, uint256 tvlUSD) external {
        poolTVLUSD[poolId] = tvlUSD;
    }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }

    function getCurrentFee(PoolId poolId) external view returns (uint24) {
        return poolFeeState[poolId].currentDynamicFee;
    }

    function previewFee(PoolId poolId, uint256 swapAmountUSD, bool mevDetected)
        external view returns (uint24)
    {
        return XenorizeMath.computeDynamicFee(
            baseFee, _getVolatility(poolId), targetVolBps,
            swapAmountUSD, poolTVLUSD[poolId], mevDetected
        );
    }
}
