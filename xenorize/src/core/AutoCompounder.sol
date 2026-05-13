// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {Position, CompoundConfig, CompoundResult, CompoundUrgency, RiskProfile, PositionStatus, InsuranceClaim, Xenorize__ZeroAddress, Xenorize__ZeroAmount, Xenorize__InvalidRange, Xenorize__PositionNotActive, Xenorize__PositionNotOwned, Xenorize__NotProfitable, Xenorize__TVLCapExceeded, Xenorize__CompoundRateLimited, Xenorize__InvalidFeeRate} from "../types/XenorizeTypes.sol";
import {IInsuranceFund, IXenorizeOracle} from "../interfaces/IXenorize.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

contract XenorizeAutoCompounder is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address        public immutable owner;
    address        public immutable poolManager;
    IInsuranceFund public immutable insuranceFund;
    IERC20         public immutable token0;
    IERC20         public immutable token1;
    IXenorizeOracle public oracle;

    uint256 public protocolFeeBps   = 200;
    uint256 public keeperRewardBps  = 50;
    uint256 public maxTVLCap        = 50_000e18;
    uint256 public minDepositAmount = 100e18;
    uint256 public totalTVL;
    uint256 public totalPositions;

    mapping(bytes32 => Position)       private _positions;
    mapping(bytes32 => CompoundConfig) private _configs;
    mapping(address => bytes32[])      private _ownerPositions;
    mapping(RiskProfile => int24)      public rangeWidthTicks;
    mapping(bytes32 => uint256)        public lastCompoundBlock;

    event PositionOpened(bytes32 indexed id, address indexed owner, bytes32 indexed poolId, int24 tL, int24 tU, uint256 a0, uint256 a1);
    event PositionCompounded(bytes32 indexed id, uint256 cycle, int24 tL, int24 tU, uint256 f0, uint256 f1, uint256 il, uint256 net);
    event PositionClosed(bytes32 indexed id, address indexed owner, uint256 r0, uint256 r1, uint256 tf0, uint256 tf1, uint256 il, uint256 cycles);
    event FeesCollected(bytes32 indexed id, uint256 f0, uint256 f1);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__PositionNotOwned(bytes32(0), msg.sender);
        _;
    }
    modifier positionActive(bytes32 id) {
        Position storage p = _positions[id];
        if (p.status == PositionStatus.Closed || p.owner == address(0))
            revert Xenorize__PositionNotActive(id);
        _;
    }
    modifier onlyOwnerOrKeeper(bytes32 id) {
        if (msg.sender != _positions[id].owner && msg.sender != owner)
            revert Xenorize__PositionNotOwned(id, msg.sender);
        _;
    }

    constructor(
        address _owner, address _poolManager, address _insuranceFund,
        address _token0, address _token1, address _oracle
    ) {
        if (_owner == address(0) || _poolManager == address(0) ||
            _insuranceFund == address(0) || _token0 == address(0) || _token1 == address(0))
            revert Xenorize__ZeroAddress();
        owner         = _owner;
        poolManager   = _poolManager;
        insuranceFund = IInsuranceFund(_insuranceFund);
        token0        = IERC20(_token0);
        token1        = IERC20(_token1);
        oracle        = IXenorizeOracle(_oracle);
        rangeWidthTicks[RiskProfile.Conservative] = 8_000;
        rangeWidthTicks[RiskProfile.Balanced]     = 3_000;
        rangeWidthTicks[RiskProfile.Aggressive]   = 1_000;
    }

    function openPosition(
        bytes32 poolId, int24 tickLower, int24 tickUpper,
        uint256 amount0, uint256 amount1,
        RiskProfile riskProfile, CompoundConfig calldata config
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        if (amount0 == 0 && amount1 == 0) revert Xenorize__ZeroAmount();
        if (tickLower >= tickUpper) revert Xenorize__InvalidRange(tickLower, tickUpper);

        uint256 depositVal = amount0 + amount1;
        if (totalTVL + depositVal > maxTVLCap) revert Xenorize__TVLCapExceeded(totalTVL, maxTVLCap);
        if (depositVal < minDepositAmount) revert Xenorize__ZeroAmount();

        positionId = keccak256(abi.encodePacked(msg.sender, poolId, tickLower, tickUpper, block.timestamp, totalPositions));

        _positions[positionId] = Position({
            owner: msg.sender, poolId: poolId,
            tickLower: tickLower, tickUpper: tickUpper,
            liquidity: uint128(amount0 + amount1),
            depositTime: block.timestamp, lastCompound: block.timestamp,
            compoundCount: 0, initialCapital0: amount0, initialCapital1: amount1,
            totalFees0: 0, totalFees1: 0, totalIL0: 0,
            riskProfile: riskProfile, status: PositionStatus.Active
        });
        _configs[positionId] = config;
        _ownerPositions[msg.sender].push(positionId);

        totalTVL += depositVal;
        totalPositions++;

        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);

        emit PositionOpened(positionId, msg.sender, poolId, tickLower, tickUpper, amount0, amount1);
    }

    function compoundPosition(bytes32 id, int24 newTickLower, int24 newTickUpper)
        external nonReentrant whenNotPaused positionActive(id)
        returns (CompoundResult memory result)
    {
        if (lastCompoundBlock[id] == block.number) revert Xenorize__CompoundRateLimited(block.number + 1);
        if (newTickLower >= newTickUpper) revert Xenorize__InvalidRange(newTickLower, newTickUpper);

        Position storage pos = _positions[id];
        lastCompoundBlock[id] = block.number;

        uint256 oldCycle;
        uint256 netFee0;

        {   // scoped block: free fees/kFee stack slots before emit
            uint256 fees0 = pos.liquidity / 100;
            uint256 fees1 = pos.liquidity / 100;

            result.ilRealized0 = XenorizeMath.calculateILAmount(
                pos.initialCapital0, pos.initialCapital1, 1e18, 1e18
            );
            pos.totalIL0 += result.ilRealized0;

            result.protocolFee0   = (fees0 * protocolFeeBps) / 10_000;
            result.protocolFee1   = (fees1 * protocolFeeBps) / 10_000;
            result.feesCollected0 = fees0;
            result.feesCollected1 = fees1;

            uint256 kFee0;
            uint256 kFee1;
            if (msg.sender != pos.owner) {
                kFee0 = ((fees0 - result.protocolFee0) * keeperRewardBps) / 10_000;
                kFee1 = ((fees1 - result.protocolFee1) * keeperRewardBps) / 10_000;
                if (kFee0 > 0 && token0.balanceOf(address(this)) >= kFee0)
                    token0.safeTransfer(msg.sender, kFee0);
            }

            result.newCapital0 = pos.initialCapital0 + fees0 - result.protocolFee0 - kFee0;
            result.newCapital1 = pos.initialCapital1 + fees1 - result.protocolFee1 - kFee1;
            netFee0 = fees0 - result.protocolFee0 - kFee0;
        }

        result.newTickLower = newTickLower;
        result.newTickUpper = newTickUpper;

        oldCycle            = pos.compoundCount;
        pos.tickLower       = newTickLower;
        pos.tickUpper       = newTickUpper;
        pos.liquidity       = uint128(result.newCapital0 + result.newCapital1);
        pos.lastCompound    = block.timestamp;
        pos.compoundCount++;
        pos.totalFees0      += result.feesCollected0;
        pos.totalFees1      += result.feesCollected1;
        pos.initialCapital0 = result.newCapital0;
        pos.initialCapital1 = result.newCapital1;

        emit PositionCompounded(
            id, oldCycle + 1, newTickLower, newTickUpper,
            result.feesCollected0, result.feesCollected1, result.ilRealized0,
            netFee0
        );
    }

    function closePosition(bytes32 id)
        external nonReentrant positionActive(id) onlyOwnerOrKeeper(id)
        returns (uint256 returned0, uint256 returned1)
    {
        Position storage pos = _positions[id];
        pos.status = PositionStatus.Closed;
        totalTVL   = totalTVL > pos.initialCapital0 + pos.initialCapital1
            ? totalTVL - pos.initialCapital0 - pos.initialCapital1 : 0;

        returned0 = pos.initialCapital0;
        returned1 = pos.initialCapital1;

        if (returned0 > 0 && token0.balanceOf(address(this)) >= returned0)
            token0.safeTransfer(pos.owner, returned0);
        if (returned1 > 0 && token1.balanceOf(address(this)) >= returned1)
            token1.safeTransfer(pos.owner, returned1);

        emit PositionClosed(id, pos.owner, returned0, returned1, pos.totalFees0, pos.totalFees1, pos.totalIL0, pos.compoundCount);
    }

    function collectFees(bytes32 id)
        external nonReentrant whenNotPaused positionActive(id) onlyOwnerOrKeeper(id)
        returns (uint256 fees0, uint256 fees1)
    {
        Position storage pos = _positions[id];
        fees0 = pos.liquidity / 200;
        fees1 = pos.liquidity / 200;
        pos.totalFees0 += fees0;
        pos.totalFees1 += fees1;
        if (fees0 > 0 && token0.balanceOf(address(this)) >= fees0) token0.safeTransfer(pos.owner, fees0);
        if (fees1 > 0 && token1.balanceOf(address(this)) >= fees1) token1.safeTransfer(pos.owner, fees1);
        emit FeesCollected(id, fees0, fees1);
    }

    function getPosition(bytes32 id) external view returns (Position memory) { return _positions[id]; }
    function getPositionsByOwner(address a) external view returns (bytes32[] memory) { return _ownerPositions[a]; }
    function getConfig(bytes32 id) external view returns (CompoundConfig memory) { return _configs[id]; }

    function getCompoundUrgency(bytes32 id) external view returns (CompoundUrgency) {
        Position storage pos = _positions[id];
        if (pos.status == PositionStatus.Closed)    return CompoundUrgency.None;
        if (pos.status == PositionStatus.OutOfRange) return CompoundUrgency.Immediate;
        uint256 h = (block.timestamp - pos.lastCompound) / 3600;
        if (h > 48) return CompoundUrgency.High;
        if (h > 24) return CompoundUrgency.Medium;
        if (h > 6)  return CompoundUrgency.Low;
        return CompoundUrgency.None;
    }

    function setProtocolFee(uint256 bps) external onlyOwner {
        if (bps > 1_000) revert Xenorize__InvalidFeeRate(bps, 1_000);
        protocolFeeBps = bps;
    }
    function setMaxTVLCap(uint256 cap) external onlyOwner { maxTVLCap = cap; }
    function setOracle(address a) external onlyOwner { oracle = IXenorizeOracle(a); }
    function emergencyPause() external onlyOwner { _pause(); }
    function emergencyUnpause() external onlyOwner { _unpause(); }
}
