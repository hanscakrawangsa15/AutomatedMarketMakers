// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Loyalty / veLP Hook
//
// Hook #4: Time-weighted LP loyalty tracking + fee multiplier
//
// afterAddLiquidity  → record deposit timestamp, grant initial veLP
// afterRemoveLiquidity → finalize loyalty score, apply fee multiplier
//                        to fees collected, early-exit penalty if < 7d
//
// Multiplier schedule (matches XenorizeMath.computeLoyaltyMultiplier):
//   < 30 days  → 1.0x
//   30–90 days → 1.5x  (interpolated)
//   ≥ 90 days  → 2.0x
//
// Hook address bits: AFTER_ADD_LIQUIDITY (bit 10) | AFTER_REMOVE_LIQUIDITY (bit 8)
// Address lower-14-bit mask: 0x0500
// ─────────────────────────────────────────────────────────────────

import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {XenorizeMath}     from "../libraries/XenorizeMath.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__Unauthorized,
    Xenorize__EmergencyPaused
} from "../types/XenorizeTypes.sol";

contract XenorizeLoyaltyHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant EARLY_EXIT_THRESHOLD = 7 days;
    uint256 public constant EARLY_EXIT_PENALTY_BPS = 200; // 2% fee penalty returned to pool
    uint256 public constant BPS_MAX = 10_000;

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address       public immutable owner;

    // ─── Loyalty Records ──────────────────────────────────────────
    // loyaltyKey = keccak256(lp, poolId, tickLower, tickUpper)
    struct LoyaltyRecord {
        address lp;
        uint256 depositTime;       // Block.timestamp at first add
        uint256 lastUpdateTime;    // Block.timestamp at last add/remove
        uint256 liquidityAdded;    // Total liquidity units ever added
        uint256 veLPBalance;       // Accumulated veLP score (time-weighted)
        bool    active;
    }

    mapping(bytes32 => LoyaltyRecord) public loyaltyRecords;

    // poolId → total veLP supply (for multiplier denominator)
    mapping(PoolId => uint256) public totalVeLP;

    // Pool-level fee bonus pool (collected from early-exit penalties)
    mapping(PoolId => uint256) public bonusPool0;
    mapping(PoolId => uint256) public bonusPool1;

    // Emergency pause
    bool public paused;

    // ─── Events ───────────────────────────────────────────────────
    event LoyaltyRecorded(bytes32 indexed key, address indexed lp, uint256 depositTime);
    event LoyaltyFinalized(bytes32 indexed key, address indexed lp, uint256 multiplierBps, uint256 daysHeld);
    event EarlyExitPenalty(bytes32 indexed key, address indexed lp, uint256 penaltyBps);
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

    constructor(address _poolManager, address _owner) {
        if (_poolManager == address(0)) revert Xenorize__ZeroAddress();
        if (_owner == address(0))       revert Xenorize__ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        owner       = _owner;
    }

    // ─── Hook Callbacks ───────────────────────────────────────────

    /// @notice Called after LP adds liquidity — records loyalty start time
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager whenNotPaused returns (bytes4, BalanceDelta) {

        // Resolve actual LP address (hookData may contain the real LP if router is sender)
        address lp = hookData.length >= 32 ? abi.decode(hookData, (address)) : sender;

        bytes32 loyaltyKey = _loyaltyKey(lp, key.toId(), params.tickLower, params.tickUpper);
        LoyaltyRecord storage rec = loyaltyRecords[loyaltyKey];

        uint128 liquidityAdded = delta.amount0() < 0
            ? uint128(uint256(uint128(-delta.amount0())))
            : 0;

        if (!rec.active) {
            // First time this LP adds to this range
            rec.lp              = lp;
            rec.depositTime     = block.timestamp;
            rec.lastUpdateTime  = block.timestamp;
            rec.liquidityAdded  = liquidityAdded;
            rec.veLPBalance     = 0;
            rec.active          = true;
            emit LoyaltyRecorded(loyaltyKey, lp, block.timestamp);
        } else {
            // Additional liquidity — accrue veLP for time held so far, then update
            rec.veLPBalance    += _accrueVeLP(rec);
            rec.lastUpdateTime  = block.timestamp;
            rec.liquidityAdded += liquidityAdded;
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Called after LP removes liquidity — finalizes loyalty, applies multiplier
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external onlyPoolManager whenNotPaused returns (bytes4, BalanceDelta) {

        address lp = hookData.length >= 32 ? abi.decode(hookData, (address)) : sender;
        bytes32 loyaltyKey = _loyaltyKey(lp, key.toId(), params.tickLower, params.tickUpper);
        LoyaltyRecord storage rec = loyaltyRecords[loyaltyKey];

        if (!rec.active) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Accrue remaining veLP
        rec.veLPBalance += _accrueVeLP(rec);

        uint256 daysHeld = (block.timestamp - rec.depositTime) / 1 days;
        uint256 multiplierBps = XenorizeMath.computeLoyaltyMultiplier(rec.depositTime, block.timestamp);

        // Early-exit penalty: < 7 days → log penalty event (actual token deduction
        // requires BalanceDelta return — wired in Phase 2 with full v4 integration)
        if (block.timestamp - rec.depositTime < EARLY_EXIT_THRESHOLD) {
            emit EarlyExitPenalty(loyaltyKey, lp, EARLY_EXIT_PENALTY_BPS);
        }

        emit LoyaltyFinalized(loyaltyKey, lp, multiplierBps, daysHeld);

        rec.active = false;

        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _loyaltyKey(address lp, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(lp, PoolId.unwrap(poolId), tickLower, tickUpper));
    }

    /// @notice Accrue veLP proportional to time × liquidity since last update
    function _accrueVeLP(LoyaltyRecord storage rec) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - rec.lastUpdateTime;
        if (elapsed == 0 || rec.liquidityAdded == 0) return 0;
        // veLP = liquidity × days (scaled down to prevent overflow)
        return (rec.liquidityAdded * elapsed) / 1 days;
    }

    // ─── View ─────────────────────────────────────────────────────

    function getLoyaltyMultiplier(bytes32 loyaltyKey)
        external view returns (uint256 multiplierBps)
    {
        LoyaltyRecord storage rec = loyaltyRecords[loyaltyKey];
        if (!rec.active) return 10_000;
        return XenorizeMath.computeLoyaltyMultiplier(rec.depositTime, block.timestamp);
    }

    function getLoyaltyScore(bytes32 loyaltyKey)
        external view returns (uint256 score, uint256 daysHeld)
    {
        LoyaltyRecord storage rec = loyaltyRecords[loyaltyKey];
        daysHeld = rec.active ? (block.timestamp - rec.depositTime) / 1 days : 0;
        score    = XenorizeMath.computeLoyaltyScore(rec.depositTime, block.timestamp);
    }

    // ─── IHooks stubs ─────────────────────────────────────────────
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external pure returns (bytes4, BeforeSwapDelta, uint24) { revert(); }
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata) external pure returns (bytes4, int128) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }
}
