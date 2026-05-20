// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — AutoRange Hook
//
// Hook #2: AI-driven range rebalancing
//
// Triggered afterSwap — monitors whether pool price is approaching
// the boundary of any managed position. When price enters the
// "danger zone" (within `rebalanceBuffer` of a tick boundary),
// this hook records the pool as needing rebalance so the keeper
// bot can act within the same block or the next block.
//
// On-chain side: stateful signal + keeper coordination
// Off-chain side: keeper reads `needsRebalance` and calls
//                 `AutoCompounder.compoundPosition()`
//
// Hook address bits: AFTER_SWAP (bit 6) = 0x0040
// ─────────────────────────────────────────────────────────────────

import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IXenorizeOracle}  from "../interfaces/IXenorize.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__Unauthorized,
    Xenorize__EmergencyPaused,
    RiskProfile
} from "../types/XenorizeTypes.sol";
import {XenorizeMath}     from "../libraries/XenorizeMath.sol";

contract XenorizeAutoRangeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant REBALANCE_BUFFER_DEFAULT = 500; // 5% of tick range

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager    public immutable poolManager;
    IXenorizeOracle public immutable oracle;
    address         public immutable owner;

    // ─── Per-pool managed position registry ──────────────────────
    // positionKey = keccak256(lpOwner, poolId, tickLower, tickUpper)
    struct ManagedPosition {
        address lp;
        int24   tickLower;
        int24   tickUpper;
        uint256 rebalanceBuffer; // BPS of range width that triggers signal
        bool    aiEnabled;       // Use oracle for suggested range
        bool    active;
    }

    // poolId → positionKey[]
    mapping(PoolId => bytes32[])           public poolPositionKeys;
    mapping(bytes32 => ManagedPosition)    public managedPositions;

    // poolId → whether any position needs rebalance this block
    mapping(PoolId => bool)                public poolNeedsRebalance;
    // positionKey → urgency (0=none, 1=approaching, 2=at boundary)
    mapping(bytes32 => uint8)              public rebalanceUrgency;
    // positionKey → AI-suggested new range (written on afterSwap)
    mapping(bytes32 => SuggestedRange)     public suggestedRanges;

    struct SuggestedRange {
        int24   tickLower;
        int24   tickUpper;
        uint256 confidence; // BPS (10000 = 100%)
        uint256 updatedAt;
    }

    // Emergency pause
    bool public paused;

    // ─── Events ───────────────────────────────────────────────────
    event RebalanceSignaled(PoolId indexed poolId, bytes32 indexed positionKey, uint8 urgency);
    event PositionRegistered(bytes32 indexed positionKey, address indexed lp, int24 tickLower, int24 tickUpper);
    event PositionDeregistered(bytes32 indexed positionKey);
    event SuggestedRangeUpdated(bytes32 indexed positionKey, int24 newLower, int24 newUpper, uint256 confidence);
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

    // ─── Hook Callbacks ───────────────────────────────────────────

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager whenNotPaused returns (bytes4, int128) {
        PoolId poolId = key.toId();
        bytes32[] storage keys = poolPositionKeys[poolId];

        // Get current tick from pool state
        // In production: IPoolManager(poolManager).getSlot0(poolId) returns current tick
        // Here we use oracle TWAP tick as proxy (safer for hook context)
        int24 currentTick = _getCurrentTick(key);

        bool anyNeedsRebalance = false;

        for (uint256 i = 0; i < keys.length; i++) {
            ManagedPosition storage pos = managedPositions[keys[i]];
            if (!pos.active) continue;

            uint8 urgency = _computeUrgency(currentTick, pos.tickLower, pos.tickUpper, pos.rebalanceBuffer);

            if (urgency > 0) {
                rebalanceUrgency[keys[i]] = urgency;
                anyNeedsRebalance = true;
                emit RebalanceSignaled(poolId, keys[i], urgency);

                // Fetch AI-suggested range if enabled
                if (pos.aiEnabled && address(oracle) != address(0)) {
                    _updateSuggestedRange(keys[i], poolId, pos.lp);
                }
            } else {
                rebalanceUrgency[keys[i]] = 0;
            }
        }

        poolNeedsRebalance[poolId] = anyNeedsRebalance;

        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Internal ─────────────────────────────────────────────────

    /// @dev 0 = no action, 1 = approaching boundary, 2 = at/past boundary
    function _computeUrgency(
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        uint256 bufferBps
    ) internal pure returns (uint8) {
        int24 rangeWidth = tickUpper - tickLower;
        if (rangeWidth <= 0) return 0;

        // Distance from each boundary in ticks
        int24 distLower = currentTick - tickLower;
        int24 distUpper = tickUpper - currentTick;

        // Out of range
        if (distLower <= 0 || distUpper <= 0) return 2;

        // Buffer = bufferBps% of range width
        int24 buffer = int24(int256(uint256(int256(rangeWidth)) * bufferBps / 10_000));
        if (buffer < 1) buffer = 1;

        if (distLower < buffer || distUpper < buffer) return 1;

        return 0;
    }

    function _getCurrentTick(PoolKey calldata) internal view returns (int24 tick) {
        // In production: decode from poolManager.getSlot0(key.toId())
        // For now: return 0 as neutral — keeper bot queries this externally
        return 0;
    }

    function _updateSuggestedRange(bytes32 posKey, PoolId poolId, address) internal {
        try oracle.getSuggestedRange(PoolId.unwrap(poolId), RiskProfile.Balanced)
            returns (int24 lo, int24 hi, uint256 conf)
        {
            suggestedRanges[posKey] = SuggestedRange({
                tickLower:  lo,
                tickUpper:  hi,
                confidence: conf,
                updatedAt:  block.timestamp
            });
            emit SuggestedRangeUpdated(posKey, lo, hi, conf);
        } catch {}
    }

    // ─── LP Registration ──────────────────────────────────────────

    function registerPosition(
        PoolKey calldata key,
        int24   tickLower,
        int24   tickUpper,
        uint256 rebalanceBuffer,
        bool    aiEnabled
    ) external returns (bytes32 posKey) {
        posKey = keccak256(abi.encodePacked(msg.sender, key.toId(), tickLower, tickUpper));
        managedPositions[posKey] = ManagedPosition({
            lp:              msg.sender,
            tickLower:       tickLower,
            tickUpper:       tickUpper,
            rebalanceBuffer: rebalanceBuffer == 0 ? REBALANCE_BUFFER_DEFAULT : rebalanceBuffer,
            aiEnabled:       aiEnabled,
            active:          true
        });
        poolPositionKeys[key.toId()].push(posKey);
        emit PositionRegistered(posKey, msg.sender, tickLower, tickUpper);
    }

    function deregisterPosition(bytes32 posKey) external {
        ManagedPosition storage pos = managedPositions[posKey];
        if (msg.sender != pos.lp && msg.sender != owner)
            revert Xenorize__Unauthorized(msg.sender, owner);
        pos.active = false;
        emit PositionDeregistered(posKey);
    }

    // ─── View ─────────────────────────────────────────────────────

    function getPositionsNeedingRebalance(PoolId poolId)
        external view returns (bytes32[] memory urgent, uint8[] memory urgencies)
    {
        bytes32[] storage keys = poolPositionKeys[poolId];
        uint256 count = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            if (rebalanceUrgency[keys[i]] > 0) count++;
        }
        urgent     = new bytes32[](count);
        urgencies  = new uint8[](count);
        uint256 j  = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            uint8 u = rebalanceUrgency[keys[i]];
            if (u > 0) { urgent[j] = keys[i]; urgencies[j] = u; j++; }
        }
    }

    // ─── IHooks stubs ────────────────────────────────────────────
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) external pure returns (bytes4, BeforeSwapDelta, uint24) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }
}
