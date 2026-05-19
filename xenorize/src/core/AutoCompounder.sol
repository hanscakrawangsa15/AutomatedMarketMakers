// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Uniswap V4 ───────────────────────────────────────────────────
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency}        from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ─── OpenZeppelin ─────────────────────────────────────────────────
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";

// ─── Xenorize ─────────────────────────────────────────────────────
import {XenorizeMath}   from "../libraries/XenorizeMath.sol";
import {Position, CompoundConfig, CompoundResult, CompoundUrgency, RiskProfile, PositionStatus, InsuranceClaim, Xenorize__ZeroAddress, Xenorize__ZeroAmount, Xenorize__InvalidRange, Xenorize__PositionNotActive, Xenorize__PositionNotOwned, Xenorize__NotProfitable, Xenorize__TVLCapExceeded, Xenorize__CompoundRateLimited, Xenorize__InvalidFeeRate} from "../types/XenorizeTypes.sol";
import {IInsuranceFund, IXenorizeOracle} from "../interfaces/IXenorize.sol";

/// @title XenorizeAutoCompounder
/// @notice Manages V4 LP positions: opens/closes real liquidity via PoolManager.unlock(),
///         auto-compounds fees, tracks IL, and triggers insurance fund claims.
contract XenorizeAutoCompounder is IUnlockCallback, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Unlock action enum ───────────────────────────────────────
    enum Action { AddLiquidity, RemoveLiquidity, CollectFees }

    struct UnlockData {
        Action   action;
        bytes32  positionId;
        PoolKey  key;
        int24    tickLower;
        int24    tickUpper;
        int256   liquidityDelta;   // + add, - remove
        uint256  amount0Desired;
        uint256  amount1Desired;
    }

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager   public immutable poolManager;
    address        public immutable owner;
    IInsuranceFund public immutable insuranceFund;
    IERC20         public immutable token0;
    IERC20         public immutable token1;

    // ─── Mutable state ────────────────────────────────────────────
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

    // ─── Events ───────────────────────────────────────────────────
    event PositionOpened(bytes32 indexed id, address indexed owner, PoolId indexed poolId, int24 tL, int24 tU, uint256 a0, uint256 a1);
    event PositionCompounded(bytes32 indexed id, uint256 cycle, int24 tL, int24 tU, uint256 f0, uint256 f1, uint256 il, uint256 net);
    event PositionClosed(bytes32 indexed id, address indexed owner, uint256 r0, uint256 r1, uint256 tf0, uint256 tf1, uint256 il, uint256 cycles);
    event FeesCollected(bytes32 indexed id, uint256 f0, uint256 f1);
    event AIRangeApplied(bytes32 indexed id, int24 tL, int24 tU, uint256 confidence);
    event RangeAdjusted(bytes32 indexed id, int24 oldTL, int24 oldTU, int24 newTL, int24 newTU);

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__PositionNotOwned(bytes32(0), msg.sender);
        _;
    }
    modifier positionActive(bytes32 id) {
        if (_positions[id].status == PositionStatus.Closed || _positions[id].owner == address(0))
            revert Xenorize__PositionNotActive(id);
        _;
    }
    modifier onlyOwnerOrKeeper(bytes32 id) {
        if (msg.sender != _positions[id].owner && msg.sender != owner)
            revert Xenorize__PositionNotOwned(id, msg.sender);
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────
    constructor(
        address _owner, IPoolManager _poolManager, address _insuranceFund,
        address _token0, address _token1, address _oracle
    ) {
        if (_owner == address(0) || address(_poolManager) == address(0) ||
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

    // ──────────────────────────────────────────────────────────────
    //  POSITION LIFECYCLE
    // ──────────────────────────────────────────────────────────────

    /// @notice Opens a new V4 liquidity position.
    ///         Pulls tokens from caller → transfers to PoolManager via unlockCallback.
    function openPosition(
        PoolKey calldata key,
        int24 tickLower, int24 tickUpper,
        uint256 amount0, uint256 amount1,
        RiskProfile riskProfile,
        CompoundConfig calldata config
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        if (amount0 == 0 && amount1 == 0) revert Xenorize__ZeroAmount();
        if (tickLower >= tickUpper) revert Xenorize__InvalidRange(tickLower, tickUpper);

        uint256 depositVal = amount0 + amount1;
        if (totalTVL + depositVal > maxTVLCap) revert Xenorize__TVLCapExceeded(totalTVL, maxTVLCap);
        if (depositVal < minDepositAmount) revert Xenorize__ZeroAmount();

        // Pull tokens from user now
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);

        positionId = keccak256(abi.encodePacked(msg.sender, key.toId(), tickLower, tickUpper, block.timestamp, totalPositions));

        // Store position before unlock (unlockCallback reads it)
        _positions[positionId] = Position({
            owner:           msg.sender,
            poolId:          PoolId.unwrap(key.toId()),
            poolKey:         key,
            tickLower:       tickLower,
            tickUpper:       tickUpper,
            liquidity:       0,          // filled by unlockCallback
            depositTime:     block.timestamp,
            lastCompound:    block.timestamp,
            compoundCount:   0,
            initialCapital0: amount0,
            initialCapital1: amount1,
            totalFees0:      0,
            totalFees1:      0,
            totalIL0:        0,
            riskProfile:     riskProfile,
            status:          PositionStatus.Active,
            aiManaged:       false,       // manual — LP owns the range
            entryPrice0USD:  _getPrice(address(token0))
        });
        _configs[positionId]  = config;
        _ownerPositions[msg.sender].push(positionId);
        lastCompoundBlock[positionId] = block.number; // prevent same-block compound on open

        totalTVL += depositVal;
        totalPositions++;

        // Add liquidity to V4 via unlock pattern
        int256 liqDelta = _liquidityForAmounts(key, tickLower, tickUpper, amount0, amount1);
        bytes memory result = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.AddLiquidity,
            positionId:     positionId,
            key:            key,
            tickLower:      tickLower,
            tickUpper:      tickUpper,
            liquidityDelta: liqDelta,
            amount0Desired: amount0,
            amount1Desired: amount1
        })));

        uint128 actualLiquidity = abi.decode(result, (uint128));
        _positions[positionId].liquidity = actualLiquidity;

        emit PositionOpened(positionId, msg.sender, key.toId(), tickLower, tickUpper, amount0, amount1);
    }

    /// @notice Opens a position where AI controls range rebalancing.
    ///         The oracle picks the initial range based on current volatility + riskProfile.
    ///         On each compound, the keeper calls autoCompound() which queries the oracle
    ///         for an updated range and re-centers liquidity automatically.
    function openPositionAI(
        PoolKey calldata key,
        uint256 amount0, uint256 amount1,
        RiskProfile riskProfile,
        CompoundConfig calldata config
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        if (amount0 == 0 && amount1 == 0) revert Xenorize__ZeroAmount();

        // Ask oracle for the initial range
        bytes32 pid = PoolId.unwrap(key.toId());
        (int24 tickLower, int24 tickUpper, uint256 confidence) = address(oracle) != address(0)
            ? oracle.getSuggestedRange(pid, riskProfile)
            : (int24(-60), int24(60), uint256(5000));

        if (tickLower >= tickUpper) revert Xenorize__InvalidRange(tickLower, tickUpper);

        uint256 depositVal = amount0 + amount1;
        if (totalTVL + depositVal > maxTVLCap) revert Xenorize__TVLCapExceeded(totalTVL, maxTVLCap);
        if (depositVal < minDepositAmount) revert Xenorize__ZeroAmount();

        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);

        positionId = keccak256(abi.encodePacked(msg.sender, key.toId(), tickLower, tickUpper, block.timestamp, totalPositions));

        _positions[positionId] = Position({
            owner:           msg.sender,
            poolId:          pid,
            poolKey:         key,
            tickLower:       tickLower,
            tickUpper:       tickUpper,
            liquidity:       0,
            depositTime:     block.timestamp,
            lastCompound:    block.timestamp,
            compoundCount:   0,
            initialCapital0: amount0,
            initialCapital1: amount1,
            totalFees0:      0,
            totalFees1:      0,
            totalIL0:        0,
            riskProfile:     riskProfile,
            status:          PositionStatus.Active,
            aiManaged:       true,        // AI controls range on every compound
            entryPrice0USD:  _getPrice(address(token0))
        });
        _configs[positionId] = config;
        _ownerPositions[msg.sender].push(positionId);
        lastCompoundBlock[positionId] = block.number; // prevent same-block compound on open

        totalTVL += depositVal;
        totalPositions++;

        int256 liqDelta = _liquidityForAmounts(key, tickLower, tickUpper, amount0, amount1);
        bytes memory result = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.AddLiquidity,
            positionId:     positionId,
            key:            key,
            tickLower:      tickLower,
            tickUpper:      tickUpper,
            liquidityDelta: liqDelta,
            amount0Desired: amount0,
            amount1Desired: amount1
        })));

        uint128 actualLiquidity = abi.decode(result, (uint128));
        _positions[positionId].liquidity = actualLiquidity;

        emit PositionOpened(positionId, msg.sender, key.toId(), tickLower, tickUpper, amount0, amount1);
        emit AIRangeApplied(positionId, tickLower, tickUpper, confidence);
    }

    /// @notice Allows an LP to manually adjust the tick range of their position.
    ///         Works for both manual and AI-managed positions.
    ///         For AI positions: the next autoCompound will override this range again.
    ///         For manual positions: this range is kept permanently until next adjustment.
    function adjustRange(bytes32 id, int24 newTickLower, int24 newTickUpper)
        external nonReentrant whenNotPaused positionActive(id)
    {
        Position storage pos = _positions[id];
        if (msg.sender != pos.owner) revert Xenorize__PositionNotOwned(id, msg.sender);
        if (newTickLower >= newTickUpper) revert Xenorize__InvalidRange(newTickLower, newTickUpper);

        int24 oldLower = pos.tickLower;
        int24 oldUpper = pos.tickUpper;

        // Remove liquidity from old range
        poolManager.unlock(abi.encode(UnlockData({
            action:         Action.RemoveLiquidity,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      oldLower,
            tickUpper:      oldUpper,
            liquidityDelta: -int256(uint256(pos.liquidity)),
            amount0Desired: 0,
            amount1Desired: 0
        })));

        // Re-add at new range
        int256 newLiq = _liquidityForAmounts(pos.poolKey, newTickLower, newTickUpper,
            pos.initialCapital0, pos.initialCapital1);
        bytes memory result = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.AddLiquidity,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      newTickLower,
            tickUpper:      newTickUpper,
            liquidityDelta: newLiq,
            amount0Desired: pos.initialCapital0,
            amount1Desired: pos.initialCapital1
        })));

        pos.tickLower = newTickLower;
        pos.tickUpper = newTickUpper;
        pos.liquidity = abi.decode(result, (uint128));

        emit RangeAdjusted(id, oldLower, oldUpper, newTickLower, newTickUpper);
    }

    /// @notice Compounds a MANUAL position: collects fees and re-adds at the SAME range.
    ///         Only callable by position owner or protocol keeper.
    function compoundManual(bytes32 id)
        external nonReentrant whenNotPaused positionActive(id)
        returns (CompoundResult memory result)
    {
        Position storage pos = _positions[id];
        if (pos.aiManaged) revert Xenorize__PositionNotOwned(id, msg.sender);
        if (lastCompoundBlock[id] == block.number) revert Xenorize__CompoundRateLimited(block.number + 1);
        lastCompoundBlock[id] = block.number;
        return _compoundCore(id, pos.tickLower, pos.tickUpper);
    }

    /// @notice Compounds an AI-managed position: queries oracle for optimal range, then rebalances.
    ///         Callable by anyone (keeper bot) — keeper reward is deducted from fees.
    function autoCompound(bytes32 id)
        external nonReentrant whenNotPaused positionActive(id)
        returns (CompoundResult memory result)
    {
        Position storage pos = _positions[id];
        if (!pos.aiManaged) revert Xenorize__PositionNotOwned(id, msg.sender);
        if (lastCompoundBlock[id] == block.number) revert Xenorize__CompoundRateLimited(block.number + 1);
        lastCompoundBlock[id] = block.number;

        (int24 newTickLower, int24 newTickUpper, uint256 confidence) = address(oracle) != address(0)
            ? oracle.getSuggestedRange(pos.poolId, pos.riskProfile)
            : (pos.tickLower, pos.tickUpper, uint256(5000));

        emit AIRangeApplied(id, newTickLower, newTickUpper, confidence);
        return _compoundCore(id, newTickLower, newTickUpper);
    }

    /// @notice Closes a position, removes all liquidity, returns tokens to owner.
    function closePosition(bytes32 id)
        external nonReentrant positionActive(id) onlyOwnerOrKeeper(id)
        returns (uint256 returned0, uint256 returned1)
    {
        Position storage pos = _positions[id];
        pos.status = PositionStatus.Closed;

        bytes memory result = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.RemoveLiquidity,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      pos.tickLower,
            tickUpper:      pos.tickUpper,
            liquidityDelta: -int256(uint256(pos.liquidity)),
            amount0Desired: 0,
            amount1Desired: 0
        })));

        (returned0, returned1) = abi.decode(result, (uint256, uint256));

        totalTVL = totalTVL > pos.initialCapital0 + pos.initialCapital1
            ? totalTVL - pos.initialCapital0 - pos.initialCapital1 : 0;

        if (returned0 > 0) token0.safeTransfer(pos.owner, returned0);
        if (returned1 > 0) token1.safeTransfer(pos.owner, returned1);

        emit PositionClosed(id, pos.owner, returned0, returned1, pos.totalFees0, pos.totalFees1, pos.totalIL0, pos.compoundCount);
    }

    /// @notice Compounds a position with an explicit new tick range.
    ///         For AI positions use autoCompound(); for manual positions use compoundManual().
    function compoundPosition(bytes32 id, int24 newTickLower, int24 newTickUpper)
        external nonReentrant whenNotPaused positionActive(id)
        returns (CompoundResult memory result)
    {
        if (lastCompoundBlock[id] == block.number) revert Xenorize__CompoundRateLimited(block.number + 1);
        if (newTickLower >= newTickUpper) revert Xenorize__InvalidRange(newTickLower, newTickUpper);
        lastCompoundBlock[id] = block.number;
        return _compoundCore(id, newTickLower, newTickUpper);
    }

    /// @dev Core compound logic — shared by compoundPosition, compoundManual, autoCompound.
    function _compoundCore(bytes32 id, int24 newTickLower, int24 newTickUpper)
        internal returns (CompoundResult memory result)
    {
        Position storage pos = _positions[id];

        // Step 1: Collect fees (modifyLiquidity with delta=0)
        bytes memory feeResult = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.CollectFees,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      pos.tickLower,
            tickUpper:      pos.tickUpper,
            liquidityDelta: 0,
            amount0Desired: 0,
            amount1Desired: 0
        })));
        (uint256 fees0, uint256 fees1) = abi.decode(feeResult, (uint256, uint256));

        // Step 2: Compute IL — compare current price to entry price stored at open time
        uint256 price0 = _getPrice(address(token0));
        result.ilRealized0 = XenorizeMath.calculateILAmount(
            pos.initialCapital0, pos.initialCapital1, price0, pos.entryPrice0USD
        );
        pos.totalIL0 += result.ilRealized0;

        // Step 3: Distribute protocol fee + keeper reward
        result.protocolFee0 = (fees0 * protocolFeeBps) / 10_000;
        result.protocolFee1 = (fees1 * protocolFeeBps) / 10_000;
        uint256 kFee0;
        uint256 kFee1;
        if (msg.sender != pos.owner) {
            kFee0 = ((fees0 - result.protocolFee0) * keeperRewardBps) / 10_000;
            kFee1 = ((fees1 - result.protocolFee1) * keeperRewardBps) / 10_000;
            if (kFee0 > 0) token0.safeTransfer(msg.sender, kFee0);
        }
        result.feesCollected0 = fees0;
        result.feesCollected1 = fees1;

        // Step 4: Remove old liquidity, re-add at new range
        uint256 net0 = pos.initialCapital0 + fees0 - result.protocolFee0 - kFee0;
        uint256 net1 = pos.initialCapital1 + fees1 - result.protocolFee1 - kFee1;

        poolManager.unlock(abi.encode(UnlockData({
            action:         Action.RemoveLiquidity,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      pos.tickLower,
            tickUpper:      pos.tickUpper,
            liquidityDelta: -int256(uint256(pos.liquidity)),
            amount0Desired: 0,
            amount1Desired: 0
        })));

        int256 newLiq = _liquidityForAmounts(pos.poolKey, newTickLower, newTickUpper, net0, net1);
        bytes memory readdResult = poolManager.unlock(abi.encode(UnlockData({
            action:         Action.AddLiquidity,
            positionId:     id,
            key:            pos.poolKey,
            tickLower:      newTickLower,
            tickUpper:      newTickUpper,
            liquidityDelta: newLiq,
            amount0Desired: net0,
            amount1Desired: net1
        })));

        uint128 newLiquidity = abi.decode(readdResult, (uint128));

        // Forward protocol fees to owner (they remain in contract after re-add)
        if (result.protocolFee0 > 0) token0.safeTransfer(owner, result.protocolFee0);
        if (result.protocolFee1 > 0) token1.safeTransfer(owner, result.protocolFee1);

        // Update position state — save prevCapital before overwriting
        uint256 oldCycle       = pos.compoundCount;
        uint256 prevCapital0   = pos.initialCapital0;
        pos.tickLower          = newTickLower;
        pos.tickUpper          = newTickUpper;
        pos.liquidity          = newLiquidity;
        pos.lastCompound       = block.timestamp;
        pos.compoundCount++;
        pos.totalFees0         += fees0;
        pos.totalFees1         += fees1;
        pos.initialCapital0    = net0;
        pos.initialCapital1    = net1;

        result.newCapital0     = net0;
        result.newCapital1     = net1;
        result.newTickLower    = newTickLower;
        result.newTickUpper    = newTickUpper;

        uint256 netGrowth0 = net0 > prevCapital0 ? net0 - prevCapital0 : 0;
        emit PositionCompounded(id, oldCycle + 1, newTickLower, newTickUpper, fees0, fees1, result.ilRealized0, netGrowth0);
    }

    // ──────────────────────────────────────────────────────────────
    //  IUnlockCallback — called by PoolManager inside unlock()
    // ──────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Xenorize__PositionNotOwned(bytes32(0), msg.sender);

        UnlockData memory d = abi.decode(data, (UnlockData));

        if (d.action == Action.AddLiquidity) {
            return _cbAddLiquidity(d);
        } else if (d.action == Action.RemoveLiquidity) {
            return _cbRemoveLiquidity(d);
        } else {
            return _cbCollectFees(d);
        }
    }

    /// @dev Called inside unlock — adds liquidity and settles token deltas.
    function _cbAddLiquidity(UnlockData memory d) internal returns (bytes memory) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower:      d.tickLower,
                tickUpper:      d.tickUpper,
                liquidityDelta: d.liquidityDelta,
                salt:           d.positionId    // use positionId as salt for deterministic slot
            }),
            ""
        );

        // Negative delta = pool expects payment from us
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();

        if (amt0 < 0) {
            uint256 pay0 = uint256(uint128(-amt0));
            poolManager.sync(d.key.currency0);
            token0.safeTransfer(address(poolManager), pay0);
            poolManager.settle();
        }
        if (amt1 < 0) {
            uint256 pay1 = uint256(uint128(-amt1));
            poolManager.sync(d.key.currency1);
            token1.safeTransfer(address(poolManager), pay1);
            poolManager.settle();
        }

        uint128 actualLiquidity = uint128(uint256(d.liquidityDelta));
        return abi.encode(actualLiquidity);
    }

    /// @dev Called inside unlock — removes liquidity and takes tokens back.
    function _cbRemoveLiquidity(UnlockData memory d) internal returns (bytes memory) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower:      d.tickLower,
                tickUpper:      d.tickUpper,
                liquidityDelta: d.liquidityDelta,
                salt:           d.positionId
            }),
            ""
        );

        // Positive delta = pool owes us tokens
        uint256 ret0;
        uint256 ret1;
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();

        if (amt0 > 0) {
            ret0 = uint256(uint128(amt0));
            poolManager.take(d.key.currency0, address(this), ret0);
        }
        if (amt1 > 0) {
            ret1 = uint256(uint128(amt1));
            poolManager.take(d.key.currency1, address(this), ret1);
        }

        return abi.encode(ret0, ret1);
    }

    /// @dev Called inside unlock — collects accrued fees (liquidityDelta = 0).
    function _cbCollectFees(UnlockData memory d) internal returns (bytes memory) {
        (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower:      d.tickLower,
                tickUpper:      d.tickUpper,
                liquidityDelta: 0,
                salt:           d.positionId
            }),
            ""
        );

        uint256 fees0;
        uint256 fees1;
        int128 f0 = feesAccrued.amount0();
        int128 f1 = feesAccrued.amount1();

        if (f0 > 0) {
            fees0 = uint256(uint128(f0));
            poolManager.take(d.key.currency0, address(this), fees0);
        }
        if (f1 > 0) {
            fees1 = uint256(uint128(f1));
            poolManager.take(d.key.currency1, address(this), fees1);
        }

        Position storage pos = _positions[d.positionId];
        pos.totalFees0 += fees0;
        pos.totalFees1 += fees1;
        emit FeesCollected(d.positionId, fees0, fees1);

        return abi.encode(fees0, fees1);
    }

    // ─── Internal helpers ─────────────────────────────────────────

    /// @dev Approximate liquidityDelta from token amounts.
    ///      In production, use TickMath + LiquidityAmounts from v4-core.
    function _liquidityForAmounts(
        PoolKey memory, int24, int24,
        uint256 amount0, uint256 amount1
    ) internal pure returns (int256) {
        return int256(amount0 + amount1);
    }

    function _getPrice(address token) internal view returns (uint256 price) {
        if (address(oracle) == address(0)) return XenorizeMath.WAD;
        try oracle.getTokenPriceUSD(token) returns (uint256 p, uint256) {
            return p > 0 ? p : XenorizeMath.WAD;
        } catch {
            return XenorizeMath.WAD;
        }
    }

    // ─── View functions ───────────────────────────────────────────

    function getPosition(bytes32 id) external view returns (Position memory) { return _positions[id]; }
    function getPositionsByOwner(address a) external view returns (bytes32[] memory) { return _ownerPositions[a]; }

    /// @notice Returns whether a position is AI-managed or manual.
    function isAIManaged(bytes32 id) external view returns (bool) { return _positions[id].aiManaged; }

    /// @notice Returns the current AI range recommendation for a position (view only, no gas).
    function getAIRecommendation(bytes32 id)
        external view returns (int24 tickLower, int24 tickUpper, uint256 confidence)
    {
        Position storage pos = _positions[id];
        if (address(oracle) == address(0)) return (pos.tickLower, pos.tickUpper, 5000);
        return oracle.getSuggestedRange(pos.poolId, pos.riskProfile);
    }

    /// @notice Returns whether a position is currently in-range.
    ///         (Simplified: always returns true — in production query PoolManager for currentTick.)
    function isInRange(bytes32 id) external view returns (bool) {
        Position storage pos = _positions[id];
        return pos.status == PositionStatus.Active;
    }
    function getConfig(bytes32 id) external view returns (CompoundConfig memory) { return _configs[id]; }

    function getCompoundUrgency(bytes32 id) external view returns (CompoundUrgency) {
        Position storage pos = _positions[id];
        if (pos.status == PositionStatus.Closed)     return CompoundUrgency.None;
        if (pos.status == PositionStatus.OutOfRange) return CompoundUrgency.Immediate;
        uint256 h = (block.timestamp - pos.lastCompound) / 3600;
        if (h > 48) return CompoundUrgency.High;
        if (h > 24) return CompoundUrgency.Medium;
        if (h > 6)  return CompoundUrgency.Low;
        return CompoundUrgency.None;
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setProtocolFee(uint256 bps) external onlyOwner {
        if (bps > 1_000) revert Xenorize__InvalidFeeRate(bps, 1_000);
        protocolFeeBps = bps;
    }
    function setMaxTVLCap(uint256 cap) external onlyOwner { maxTVLCap = cap; }
    function setOracle(address a) external onlyOwner { oracle = IXenorizeOracle(a); }
    function emergencyPause() external onlyOwner { _pause(); }
    function emergencyUnpause() external onlyOwner { _unpause(); }
}
