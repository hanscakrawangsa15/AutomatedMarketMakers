// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Multi-Position Strategy Hook
//
// Hook #6: Automatically split a single LP deposit into 3 layered ranges
//
// When LP adds liquidity, this hook orchestrates splitting capital into:
//   Layer A (20%) — Narrow  ±5%  → high fee capture
//   Layer B (50%) — Medium  ±15% → balanced
//   Layer C (30%) — Wide    ±40% → safety net
//
// afterAddLiquidity → record strategy intent + split config
// Actual liquidity splits are executed by keeper via AutoCompounder
// (hook stores the allocation, keeper executes modifyLiquidity calls)
//
// Hook address bits: AFTER_ADD_LIQUIDITY (bit 10) = 0x0400
// ─────────────────────────────────────────────────────────────────

import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {XenorizeMath}     from "../libraries/XenorizeMath.sol";
import {IXenorizeOracle}  from "../interfaces/IXenorize.sol";
import {RiskProfile} from "../types/XenorizeTypes.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__Unauthorized,
    Xenorize__EmergencyPaused
} from "../types/XenorizeTypes.sol";

contract XenorizeMultiPositionStrategyHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant BPS_MAX = 10_000;

    // Layer allocations in BPS (must sum to 10_000)
    uint256 public constant LAYER_A_BPS = 2_000; // 20% — Narrow ±5%
    uint256 public constant LAYER_B_BPS = 5_000; // 50% — Medium ±15%
    uint256 public constant LAYER_C_BPS = 3_000; // 30% — Wide   ±40%

    // Range widths in tick space (approximate)
    // 1 tick ≈ 0.01% price move → 500 ticks ≈ 5%
    int24 public constant NARROW_HALF_WIDTH  = 500;   // ±5%
    int24 public constant MEDIUM_HALF_WIDTH  = 1_500; // ±15%
    int24 public constant WIDE_HALF_WIDTH    = 4_000; // ±40%

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager    public immutable poolManager;
    IXenorizeOracle public immutable oracle;
    address         public immutable owner;

    // ─── Strategy State ───────────────────────────────────────────
    struct StrategyLayer {
        int24   tickLower;
        int24   tickUpper;
        uint256 allocationBps; // % of total capital in this layer
        bool    active;
    }

    // strategyKey = keccak256(lp, poolId)
    struct Strategy {
        address lp;
        PoolId  poolId;
        uint256 totalCapital0;  // Token0 allocated
        uint256 totalCapital1;  // Token1 allocated
        uint256 createdAt;
        bool    aiOptimized;    // Use oracle for layer range suggestions
        StrategyLayer layerA;
        StrategyLayer layerB;
        StrategyLayer layerC;
        bool    pendingExecution; // True = keeper needs to execute the splits
    }

    mapping(bytes32 => Strategy) public strategies;
    // lp → poolId → strategyKey (convenience lookup)
    mapping(address => mapping(PoolId => bytes32)) public lpStrategy;

    // Emergency pause
    bool public paused;

    // ─── Events ───────────────────────────────────────────────────
    event StrategyCreated(
        bytes32 indexed strategyKey,
        address indexed lp,
        PoolId  indexed poolId,
        int24 layerATick,
        int24 layerBTick,
        int24 layerCTick,
        bool  aiOptimized
    );
    event StrategyUpdated(bytes32 indexed strategyKey, uint256 newCapital0, uint256 newCapital1);
    event StrategyExecuted(bytes32 indexed strategyKey);
    event EmergencyPause(bool paused);

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

    constructor(address _poolManager, address _oracle, address _owner) {
        if (_poolManager == address(0)) revert Xenorize__ZeroAddress();
        if (_owner == address(0))       revert Xenorize__ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        oracle      = IXenorizeOracle(_oracle);
        owner       = _owner;
    }

    // ─── Hook Callback ────────────────────────────────────────────

    /// @notice afterAddLiquidity — if LP opted-in to multi-strategy, compute layer split
    /// @dev hookData = abi.encode(bool useMultiStrategy, bool aiOptimized, int24 currentTick, int24 tickSpacing)
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager whenNotPaused returns (bytes4, BalanceDelta) {

        if (hookData.length < 32) {
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Decode hookData
        (bool useMultiStrategy, bool aiOptimized, int24 currentTick, int24 tickSpacing) =
            abi.decode(hookData, (bool, bool, int24, int24));

        if (!useMultiStrategy) {
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        address lp = sender;
        PoolId poolId = key.toId();
        bytes32 stratKey = keccak256(abi.encodePacked(lp, PoolId.unwrap(poolId)));

        // Compute capital amounts from delta
        uint256 cap0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 cap1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;

        // Compute 3-layer tick ranges
        (StrategyLayer memory layerA, StrategyLayer memory layerB, StrategyLayer memory layerC) =
            _computeLayers(poolId, currentTick, tickSpacing, aiOptimized);

        Strategy storage strat = strategies[stratKey];

        if (!strat.pendingExecution) {
            // New strategy
            strat.lp              = lp;
            strat.poolId          = poolId;
            strat.createdAt       = block.timestamp;
            strat.aiOptimized     = aiOptimized;
        }
        strat.totalCapital0       = cap0;
        strat.totalCapital1       = cap1;
        strat.layerA              = layerA;
        strat.layerB              = layerB;
        strat.layerC              = layerC;
        strat.pendingExecution    = true;

        lpStrategy[lp][poolId] = stratKey;

        emit StrategyCreated(
            stratKey, lp, poolId,
            layerA.tickLower, layerB.tickLower, layerC.tickLower,
            aiOptimized
        );

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _computeLayers(
        PoolId poolId,
        int24  currentTick,
        int24  tickSpacing,
        bool   aiOptimized
    ) internal view returns (
        StrategyLayer memory layerA,
        StrategyLayer memory layerB,
        StrategyLayer memory layerC
    ) {
        if (aiOptimized && address(oracle) != address(0)) {
            // Ask oracle for AI-optimized ranges per risk profile
            try oracle.getSuggestedRange(PoolId.unwrap(poolId), RiskProfile.Aggressive)
                returns (int24 loA, int24 hiA, uint256)
            {
                layerA = StrategyLayer(loA, hiA, LAYER_A_BPS, true);
            } catch {
                layerA = _staticLayer(currentTick, tickSpacing, NARROW_HALF_WIDTH, LAYER_A_BPS);
            }
            try oracle.getSuggestedRange(PoolId.unwrap(poolId), RiskProfile.Balanced)
                returns (int24 loB, int24 hiB, uint256)
            {
                layerB = StrategyLayer(loB, hiB, LAYER_B_BPS, true);
            } catch {
                layerB = _staticLayer(currentTick, tickSpacing, MEDIUM_HALF_WIDTH, LAYER_B_BPS);
            }
            try oracle.getSuggestedRange(PoolId.unwrap(poolId), RiskProfile.Conservative)
                returns (int24 loC, int24 hiC, uint256)
            {
                layerC = StrategyLayer(loC, hiC, LAYER_C_BPS, true);
            } catch {
                layerC = _staticLayer(currentTick, tickSpacing, WIDE_HALF_WIDTH, LAYER_C_BPS);
            }
        } else {
            layerA = _staticLayer(currentTick, tickSpacing, NARROW_HALF_WIDTH, LAYER_A_BPS);
            layerB = _staticLayer(currentTick, tickSpacing, MEDIUM_HALF_WIDTH, LAYER_B_BPS);
            layerC = _staticLayer(currentTick, tickSpacing, WIDE_HALF_WIDTH,   LAYER_C_BPS);
        }
    }

    function _staticLayer(int24 currentTick, int24 spacing, int24 halfWidth, uint256 alloc)
        internal pure returns (StrategyLayer memory layer)
    {
        int24 lower = ((currentTick - halfWidth) / spacing) * spacing;
        int24 upper = ((currentTick + halfWidth) / spacing) * spacing;
        layer = StrategyLayer(lower, upper, alloc, true);
    }

    // ─── Keeper Interface ─────────────────────────────────────────

    /// @notice Mark strategy as executed (called by keeper/AutoCompounder after splits complete)
    function markStrategyExecuted(bytes32 stratKey) external {
        Strategy storage strat = strategies[stratKey];
        // Only owner or lp can mark
        if (msg.sender != strat.lp && msg.sender != owner)
            revert Xenorize__Unauthorized(msg.sender, owner);
        strat.pendingExecution = false;
        emit StrategyExecuted(stratKey);
    }

    // ─── View ─────────────────────────────────────────────────────

    function getStrategy(bytes32 stratKey) external view returns (
        address lp,
        uint256 capital0,
        uint256 capital1,
        bool    pending,
        int24   layerALower, int24 layerAUpper,
        int24   layerBLower, int24 layerBUpper,
        int24   layerCLower, int24 layerCUpper
    ) {
        Strategy storage s = strategies[stratKey];
        return (
            s.lp, s.totalCapital0, s.totalCapital1, s.pendingExecution,
            s.layerA.tickLower, s.layerA.tickUpper,
            s.layerB.tickLower, s.layerB.tickUpper,
            s.layerC.tickLower, s.layerC.tickUpper
        );
    }

    function getCapitalAllocation(bytes32 stratKey) external view returns (
        uint256 a0, uint256 b0, uint256 c0,
        uint256 a1, uint256 b1, uint256 c1
    ) {
        Strategy storage s = strategies[stratKey];
        a0 = (s.totalCapital0 * LAYER_A_BPS) / BPS_MAX;
        b0 = (s.totalCapital0 * LAYER_B_BPS) / BPS_MAX;
        c0 = s.totalCapital0 - a0 - b0;
        a1 = (s.totalCapital1 * LAYER_A_BPS) / BPS_MAX;
        b1 = (s.totalCapital1 * LAYER_B_BPS) / BPS_MAX;
        c1 = s.totalCapital1 - a1 - b1;
    }

    // ─── IHooks stubs ─────────────────────────────────────────────
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert(); }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert(); }
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external pure returns (bytes4, BeforeSwapDelta, uint24) { revert(); }
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external pure returns (bytes4, int128) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }
}
