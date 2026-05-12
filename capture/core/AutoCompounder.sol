// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — AutoCompounder Core
//
// The central LP manager contract. LP interacts ONLY with this.
//
// Responsibilities:
//   1. Receive LP deposits and open v4 positions
//   2. Track all position state
//   3. Execute compound cycles (close + reopen with accumulated fees)
//   4. Calculate and realize IL on close
//   5. Submit IL insurance claims
//   6. Route protocol fees to Insurance Fund
//
// Key design decisions:
//   - Positions are identified by bytes32 hash (not NFT)
//   - Anyone can trigger compound for any position (with incentive)
//   - Atomic close + open via v4 flash accounting
//   - Pull-based fee collection (LP claims, not auto-pushed)
// ─────────────────────────────────────────────────────────────────

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {XenorizeTypes} from "../types/XenorizeTypes.sol";
import {IAutoCompounder, IInsuranceFund, IXenorizeOracle} from "../interfaces/IXenorize.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract XenorizeAutoCompounder is IAutoCompounder, ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;
    using XenorizeMath for uint256;

    // ─── IMMUTABLES ──────────────────────────────────────────────
    address public immutable owner;
    address public immutable poolManager;     // Uniswap v4 PoolManager
    IInsuranceFund public immutable insuranceFund;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // ─── PROTOCOL CONFIG ─────────────────────────────────────────
    uint256 public protocolFeeBps       = 200;   // 2% of fees earned
    uint256 public keeperRewardBps      = 50;    // 0.5% reward for keeper who triggers compound
    uint256 public maxTVLCap            = 50_000e18; // $50K TVL cap initially
    uint256 public minDepositAmount     = 100e18;    // $100 minimum deposit

    IXenorizeOracle public oracle;

    // Per-risk-profile range widths (in tick units)
    mapping(XenorizeTypes.RiskProfile => int24) public rangeWidthTicks;

    // ─── POSITION STATE ──────────────────────────────────────────
    mapping(bytes32 => XenorizeTypes.Position)       private _positions;
    mapping(bytes32 => XenorizeTypes.CompoundConfig) private _configs;
    mapping(address => bytes32[])                    private _ownerPositions;
    mapping(bytes32 => uint256)                      private _positionIndex;

    uint256 public totalTVL;      // Total USD value locked (18 decimals)
    uint256 public totalPositions; // Count of all-time positions opened

    // Rate limiting: prevent compound spam
    mapping(bytes32 => uint256) public lastCompoundBlock;

    // ─── MODIFIERS ───────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, owner);
        }
        _;
    }

    modifier positionExists(bytes32 positionId) {
        if (!_positions[positionId].isActive()) {
            revert XenorizeTypes.Xenorize__PositionNotActive(positionId);
        }
        _;
    }

    modifier onlyPositionOwnerOrKeeper(bytes32 positionId) {
        address posOwner = _positions[positionId].owner;
        if (msg.sender != posOwner && msg.sender != owner) {
            revert XenorizeTypes.Xenorize__PositionNotOwned(positionId, msg.sender);
        }
        _;
    }

    // ─── CONSTRUCTOR ─────────────────────────────────────────────
    constructor(
        address _owner,
        address _poolManager,
        address _insuranceFund,
        address _token0,
        address _token1,
        address _oracle
    ) {
        if (_owner == address(0))          revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_poolManager == address(0))    revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_insuranceFund == address(0))  revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_token0 == address(0))         revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_token1 == address(0))         revert XenorizeTypes.Xenorize__ZeroAddress();

        owner          = _owner;
        poolManager    = _poolManager;
        insuranceFund  = IInsuranceFund(_insuranceFund);
        token0         = IERC20(_token0);
        token1         = IERC20(_token1);
        oracle         = IXenorizeOracle(_oracle);

        // Default range widths per risk profile (in ticks)
        rangeWidthTicks[XenorizeTypes.RiskProfile.Conservative] = 8_000;  // ±40%
        rangeWidthTicks[XenorizeTypes.RiskProfile.Balanced]     = 3_000;  // ±15%
        rangeWidthTicks[XenorizeTypes.RiskProfile.Aggressive]   = 1_000;  // ±5%
    }

    // ─── CORE: OPEN POSITION ─────────────────────────────────────

    /// @notice Open a new managed LP position
    /// @dev LP calls this to start auto-compounding strategy
    function openPosition(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        XenorizeTypes.RiskProfile riskProfile,
        XenorizeTypes.CompoundConfig calldata config
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {

        // ── CHECKS ──────────────────────────────────────────────
        if (amount0 == 0 && amount1 == 0) revert XenorizeTypes.Xenorize__ZeroAmount();
        if (tickLower >= tickUpper) {
            revert XenorizeTypes.Xenorize__InvalidRange(tickLower, tickUpper);
        }

        // TVL cap enforcement
        uint256 depositValueUSD = _estimateValueUSD(amount0, amount1);
        if (totalTVL + depositValueUSD > maxTVLCap) {
            revert XenorizeTypes.Xenorize__TVLCapExceeded(totalTVL, maxTVLCap);
        }

        if (depositValueUSD < minDepositAmount) {
            revert XenorizeTypes.Xenorize__ZeroAmount(); // Reuse for min deposit
        }

        // If AI range enabled, validate or override ticks
        if (config.aiRangeEnabled && address(oracle) != address(0)) {
            (int24 aiLower, int24 aiUpper, uint256 confidence) =
                oracle.getSuggestedRange(poolId, riskProfile);

            // Use AI range if confidence > 70%
            if (confidence > 7_000) {
                tickLower = aiLower;
                tickUpper = aiUpper;
            }
        }

        // ── EFFECTS ─────────────────────────────────────────────
        positionId = _generatePositionId(msg.sender, poolId, tickLower, tickUpper);

        _positions[positionId] = XenorizeTypes.Position({
            owner:           msg.sender,
            poolId:          poolId,
            tickLower:       tickLower,
            tickUpper:       tickUpper,
            liquidity:       0,         // Set after addLiquidity call
            depositTime:     block.timestamp,
            lastCompound:    block.timestamp,
            compoundCount:   0,
            initialCapital0: amount0,
            initialCapital1: amount1,
            totalFees0:      0,
            totalFees1:      0,
            totalIL0:        0,
            riskProfile:     riskProfile,
            status:          XenorizeTypes.PositionStatus.Active
        });

        _configs[positionId] = config;
        _ownerPositions[msg.sender].push(positionId);
        _positionIndex[positionId] = _ownerPositions[msg.sender].length - 1;

        totalTVL += depositValueUSD;
        totalPositions++;

        // ── INTERACTIONS ────────────────────────────────────────
        // Transfer tokens from LP to this contract
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);

        // Add liquidity to Uniswap v4
        uint128 liquidity = _addLiquidityToPool(poolId, tickLower, tickUpper, amount0, amount1);
        _positions[positionId].liquidity = liquidity;

        // Notify insurance fund of new TVL
        insuranceFund.updateTVL(totalTVL);

        emit PositionOpened(positionId, msg.sender, poolId, tickLower, tickUpper, amount0, amount1);
    }

    // ─── CORE: COMPOUND POSITION ─────────────────────────────────

    /// @notice Compound a position: collect fees + reopen at optimal range
    /// @dev Can be called by: position owner, keeper bot, or any address
    ///      Keepers receive keeperRewardBps of collected fees as incentive
    function compoundPosition(
        bytes32 positionId,
        int24 newTickLower,
        int24 newTickUpper
    ) external nonReentrant whenNotPaused positionExists(positionId)
      returns (XenorizeTypes.CompoundResult memory result) {

        XenorizeTypes.Position storage pos = _positions[positionId];
        XenorizeTypes.CompoundConfig memory config = _configs[positionId];

        bool isKeeper = msg.sender != pos.owner;

        // ── CHECKS ──────────────────────────────────────────────

        // Rate limit: max 1 compound per block per position
        if (lastCompoundBlock[positionId] == block.number) {
            revert XenorizeTypes.Xenorize__CompoundRateLimited(block.number + 1);
        }

        // Get AI-suggested range if enabled
        if (config.aiRangeEnabled && address(oracle) != address(0)) {
            (int24 aiLower, int24 aiUpper, uint256 confidence) =
                oracle.getSuggestedRange(pos.poolId, pos.riskProfile);
            if (confidence > 7_000) {
                newTickLower = aiLower;
                newTickUpper = aiUpper;
            }
        }

        if (newTickLower >= newTickUpper) {
            revert XenorizeTypes.Xenorize__InvalidRange(newTickLower, newTickUpper);
        }

        // ── EFFECTS (before interactions) ────────────────────────
        lastCompoundBlock[positionId] = block.number;

        // ── INTERACTIONS ────────────────────────────────────────

        // STEP 1: Remove ALL liquidity from old position
        (uint256 returned0, uint256 returned1) = _removeLiquidityFromPool(
            pos.poolId,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity
        );

        // STEP 2: Collect accumulated fees
        (uint256 fees0, uint256 fees1) = _collectFees(
            pos.poolId,
            pos.tickLower,
            pos.tickUpper
        );

        result.feesCollected0 = fees0;
        result.feesCollected1 = fees1;

        // STEP 3: Calculate IL realized
        result.ilRealized0 = XenorizeMath.calculateILAmount(
            pos.initialCapital0,
            pos.initialCapital1,
            _getCurrentPrice0USD(),
            _getInitialPrice0USD(positionId)
        );
        pos.totalIL0 += result.ilRealized0;

        // STEP 4: Take protocol fee from collected fees
        uint256 protocolFee0 = (fees0 * protocolFeeBps) / 10_000;
        uint256 protocolFee1 = (fees1 * protocolFeeBps) / 10_000;
        result.protocolFee0  = protocolFee0;
        result.protocolFee1  = protocolFee1;

        // Route protocol fee to insurance fund
        if (protocolFee0 > 0 || protocolFee1 > 0) {
            token0.approve(address(insuranceFund), protocolFee0);
            token1.approve(address(insuranceFund), protocolFee1);
            insuranceFund.deposit(protocolFee0, protocolFee1);
        }

        // STEP 5: Keeper reward (if triggered by external keeper)
        uint256 keeperFee0;
        uint256 keeperFee1;
        if (isKeeper) {
            keeperFee0 = ((fees0 - protocolFee0) * keeperRewardBps) / 10_000;
            keeperFee1 = ((fees1 - protocolFee1) * keeperRewardBps) / 10_000;
            if (keeperFee0 > 0) token0.safeTransfer(msg.sender, keeperFee0);
            if (keeperFee1 > 0) token1.safeTransfer(msg.sender, keeperFee1);
        }

        // STEP 6: Calculate net capital for new position
        result.newCapital0 = returned0 + fees0 - protocolFee0 - keeperFee0;
        result.newCapital1 = returned1 + fees1 - protocolFee1 - keeperFee1;
        result.newTickLower = newTickLower;
        result.newTickUpper = newTickUpper;

        // STEP 7: Check profitability (optional enforcement)
        if (config.minProfitUSD > 0) {
            uint256 netProfitUSD = _estimateValueUSD(
                fees0 - protocolFee0,
                fees1 - protocolFee1
            );
            if (netProfitUSD < config.minProfitUSD) {
                revert XenorizeTypes.Xenorize__NotProfitable(netProfitUSD, config.minProfitUSD);
            }
        }

        // STEP 8: Open new position with compound capital
        uint128 newLiquidity = _addLiquidityToPool(
            pos.poolId,
            newTickLower,
            newTickUpper,
            result.newCapital0,
            result.newCapital1
        );

        // STEP 9: Update position state
        uint256 oldCycleCount = pos.compoundCount;
        pos.tickLower     = newTickLower;
        pos.tickUpper     = newTickUpper;
        pos.liquidity     = newLiquidity;
        pos.lastCompound  = block.timestamp;
        pos.compoundCount++;
        pos.totalFees0    += fees0;
        pos.totalFees1    += fees1;

        // Update initial capital to new capital (for IL calc next cycle)
        pos.initialCapital0 = result.newCapital0;
        pos.initialCapital1 = result.newCapital1;

        // Submit IL insurance claim if IL was significant (>1%)
        if (result.ilRealized0 > (pos.initialCapital0 / 100)) {
            _submitInsuranceClaim(positionId, result.ilRealized0, 0);
        }

        emit PositionCompounded(
            positionId,
            oldCycleCount + 1,
            newTickLower,
            newTickUpper,
            fees0,
            fees1,
            result.ilRealized0,
            fees0 - protocolFee0 - keeperFee0
        );
    }

    // ─── CORE: CLOSE POSITION ────────────────────────────────────

    /// @notice Close position and return all funds to LP
    function closePosition(
        bytes32 positionId
    ) external nonReentrant positionExists(positionId)
      onlyPositionOwnerOrKeeper(positionId)
      returns (uint256 returned0, uint256 returned1) {

        XenorizeTypes.Position storage pos = _positions[positionId];

        // ── EFFECTS ─────────────────────────────────────────────
        pos.status = XenorizeTypes.PositionStatus.Closed;

        uint256 tvlDecrease = _estimateValueUSD(pos.initialCapital0, pos.initialCapital1);
        totalTVL = totalTVL > tvlDecrease ? totalTVL - tvlDecrease : 0;

        // ── INTERACTIONS ────────────────────────────────────────
        // Remove all liquidity
        (returned0, returned1) = _removeLiquidityFromPool(
            pos.poolId, pos.tickLower, pos.tickUpper, pos.liquidity
        );

        // Collect remaining fees
        (uint256 fees0, uint256 fees1) = _collectFees(
            pos.poolId, pos.tickLower, pos.tickUpper
        );

        returned0 += fees0;
        returned1 += fees1;

        // Calculate final IL
        uint256 finalIL = XenorizeMath.calculateILAmount(
            pos.initialCapital0,
            pos.initialCapital1,
            _getCurrentPrice0USD(),
            _getInitialPrice0USD(positionId)
        );

        // Submit insurance claim for final IL
        if (finalIL > 0) {
            _submitInsuranceClaim(positionId, finalIL, 0);
        }

        // Transfer funds back to LP
        if (returned0 > 0) token0.safeTransfer(pos.owner, returned0);
        if (returned1 > 0) token1.safeTransfer(pos.owner, returned1);

        // Update insurance fund TVL
        insuranceFund.updateTVL(totalTVL);

        emit PositionClosed(
            positionId,
            pos.owner,
            returned0,
            returned1,
            pos.totalFees0,
            pos.totalFees1,
            pos.totalIL0 + finalIL,
            pos.compoundCount
        );
    }

    // ─── CORE: COLLECT FEES ONLY ─────────────────────────────────

    /// @notice Collect accumulated fees without changing position
    function collectFees(
        bytes32 positionId
    ) external nonReentrant whenNotPaused positionExists(positionId)
      onlyPositionOwnerOrKeeper(positionId)
      returns (uint256 fees0, uint256 fees1) {

        XenorizeTypes.Position storage pos = _positions[positionId];

        (fees0, fees1) = _collectFees(pos.poolId, pos.tickLower, pos.tickUpper);

        pos.totalFees0 += fees0;
        pos.totalFees1 += fees1;

        if (fees0 > 0) token0.safeTransfer(pos.owner, fees0);
        if (fees1 > 0) token1.safeTransfer(pos.owner, fees1);

        emit FeesCollected(positionId, fees0, fees1);
    }

    // ─── INTERNAL: UNISWAP V4 INTERACTIONS ───────────────────────
    // These are stubs — replace with actual v4 PoolManager calls in production

    function _addLiquidityToPool(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint128 liquidity) {
        // Production implementation:
        // poolManager.unlock(abi.encode(UnlockData({
        //     action: Action.ADD_LIQUIDITY,
        //     poolId: poolId,
        //     tickLower: tickLower,
        //     tickUpper: tickUpper,
        //     amount0: amount0,
        //     amount1: amount1
        // })));
        //
        // In unlockCallback:
        // (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, "");
        // liquidity = uint128(uint256(int256(-delta.amount0())));

        // Stub: return placeholder liquidity
        liquidity = uint128(amount0 + amount1);
        poolId; // suppress unused warning
    }

    function _removeLiquidityFromPool(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Production: call poolManager.modifyLiquidity with negative delta
        amount0 = uint256(liquidity) / 2;
        amount1 = uint256(liquidity) / 2;
        poolId; tickLower; tickUpper; // suppress unused warnings
    }

    function _collectFees(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 fees0, uint256 fees1) {
        // Production: call poolManager.modifyLiquidity with delta=0 to collect
        fees0 = 0;
        fees1 = 0;
        poolId; tickLower; tickUpper; // suppress unused warnings
    }

    function _submitInsuranceClaim(
        bytes32 positionId,
        uint256 ilAmount0,
        uint256 ilAmount1
    ) internal {
        XenorizeTypes.Position memory pos = _positions[positionId];
        uint256 loyaltyScore = XenorizeMath.computeLoyaltyScore(
            pos.depositTime,
            block.timestamp
        );

        XenorizeTypes.InsuranceClaim memory claim = XenorizeTypes.InsuranceClaim({
            positionId:   positionId,
            ilAmount0:    ilAmount0,
            ilAmount1:    ilAmount1,
            loyaltyScore: loyaltyScore,
            proof:        ""
        });

        try insuranceFund.submitClaim(claim) {} catch {
            // Insurance claim failure should not block compound/close
        }
    }

    // ─── INTERNAL: PRICE HELPERS ─────────────────────────────────

    function _getCurrentPrice0USD() internal view returns (uint256) {
        if (address(oracle) == address(0)) return 1e18; // Assume $1 if no oracle
        (uint256 price,) = oracle.getTokenPriceUSD(address(token0));
        return price;
    }

    function _getInitialPrice0USD(bytes32 /*positionId*/) internal pure returns (uint256) {
        // Production: store initial price in position state at deposit time
        return 1e18; // Placeholder: assume $1 initial price
    }

    function _estimateValueUSD(
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256 valueUSD) {
        if (address(oracle) == address(0)) return amount0 + amount1;
        (uint256 price0,) = oracle.getTokenPriceUSD(address(token0));
        (uint256 price1,) = oracle.getTokenPriceUSD(address(token1));
        valueUSD = (amount0 * price0 + amount1 * price1) / 1e18;
    }

    function _generatePositionId(
        address posOwner,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            posOwner, poolId, tickLower, tickUpper,
            block.timestamp, totalPositions
        ));
    }

    // ─── VIEW FUNCTIONS ──────────────────────────────────────────

    function getPosition(
        bytes32 positionId
    ) external view returns (XenorizeTypes.Position memory) {
        return _positions[positionId];
    }

    function getPositionsByOwner(
        address posOwner
    ) external view returns (bytes32[] memory) {
        return _ownerPositions[posOwner];
    }

    function getCompoundUrgency(
        bytes32 positionId
    ) external view returns (XenorizeTypes.CompoundUrgency) {
        XenorizeTypes.Position memory pos = _positions[positionId];

        if (pos.status != XenorizeTypes.PositionStatus.Active) {
            return XenorizeTypes.CompoundUrgency.None;
        }

        if (pos.status == XenorizeTypes.PositionStatus.OutOfRange) {
            return XenorizeTypes.CompoundUrgency.Immediate;
        }

        uint256 hoursSince = (block.timestamp - pos.lastCompound) / 3600;
        if (hoursSince > 48) return XenorizeTypes.CompoundUrgency.High;
        if (hoursSince > 24) return XenorizeTypes.CompoundUrgency.Medium;
        if (hoursSince > 6)  return XenorizeTypes.CompoundUrgency.Low;

        return XenorizeTypes.CompoundUrgency.None;
    }

    function getConfig(
        bytes32 positionId
    ) external view returns (XenorizeTypes.CompoundConfig memory) {
        return _configs[positionId];
    }

    // ─── GOVERNANCE ──────────────────────────────────────────────

    function setProtocolFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 1_000) revert XenorizeTypes.Xenorize__InvalidFeeRate(newFeeBps, 1_000);
        protocolFeeBps = newFeeBps;
    }

    function setMaxTVLCap(uint256 newCap) external onlyOwner {
        maxTVLCap = newCap;
    }

    function setOracle(address newOracle) external onlyOwner {
        oracle = IXenorizeOracle(newOracle);
    }

    function emergencyPause() external onlyOwner { _pause(); }
    function emergencyUnpause() external onlyOwner { _unpause(); }
}

// ─── HELPER: Position status check ───────────────────────────────
library PositionLib {
    function isActive(
        XenorizeTypes.Position storage pos
    ) internal view returns (bool) {
        return pos.status == XenorizeTypes.PositionStatus.Active
            || pos.status == XenorizeTypes.PositionStatus.OutOfRange;
    }
}
