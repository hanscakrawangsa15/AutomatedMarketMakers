// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — TWAMM Hook (Time-Weighted AMM)
//
// Hook #5: Split large orders into small virtual swaps over time
//
// Mechanism:
//   1. Trader submits a LongTermOrder specifying total amount + duration
//   2. afterSwap callback executes virtual swap fractions each block
//   3. Price impact is smoothed across many blocks → LP protected from
//      sudden large IL events caused by single large swap
//
// Hook address bits: AFTER_SWAP (bit 6) = 0x0040
//
// Inspired by: Paradigm TWAMM paper (https://www.paradigm.xyz/2021/07/twamm)
// Simplified implementation — production version should use TWAMM library
// ─────────────────────────────────────────────────────────────────

import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__Unauthorized,
    Xenorize__EmergencyPaused
} from "../types/XenorizeTypes.sol";

contract XenorizeTWAMMHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant MIN_ORDER_DURATION  = 10 minutes;
    uint256 public constant MAX_ORDER_DURATION  = 7 days;
    uint256 public constant EXECUTION_INTERVAL  = 1;         // Execute every block
    uint256 public constant LARGE_ORDER_MIN_BPS = 200;       // 2% of TVL = "large" order

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address       public immutable owner;

    // ─── Long-Term Order Storage ──────────────────────────────────
    struct LongTermOrder {
        address trader;
        PoolId  poolId;
        bool    zeroForOne;       // Token0 → Token1 direction
        uint256 totalAmount;      // Total tokens to swap
        uint256 amountRemaining;  // Not yet executed
        uint256 startTime;
        uint256 endTime;
        uint256 lastExecutedTime; // Timestamp of last virtual swap
        bool    active;
    }

    // orderId → LongTermOrder
    mapping(bytes32 => LongTermOrder) public orders;

    // poolId → active orderIds
    mapping(PoolId => bytes32[]) public poolOrders;

    // poolId → virtual swap accumulator (aggregated virtual swap state per block)
    mapping(PoolId => VirtualSwapAccumulator) public swapAccumulators;

    struct VirtualSwapAccumulator {
        uint256 pendingAmount0;  // Net token0 sell (aggregated from all LTO in this pool)
        uint256 pendingAmount1;  // Net token1 sell
        uint256 lastExecuted;   // Timestamp of last execution
    }

    // Emergency pause
    bool public paused;

    // ─── Events ───────────────────────────────────────────────────
    event LongTermOrderPlaced(bytes32 indexed orderId, address indexed trader, uint256 amount, uint256 duration);
    event LongTermOrderExecuted(bytes32 indexed orderId, uint256 amountExecuted, uint256 amountRemaining);
    event LongTermOrderCancelled(bytes32 indexed orderId, address indexed trader, uint256 refunded);
    event VirtualSwapExecuted(PoolId indexed poolId, uint256 amount0, uint256 amount1);
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

    // ─── Order Placement ─────────────────────────────────────────

    /// @notice Place a long-term order to be executed in small increments
    /// @param key         Pool to swap in
    /// @param zeroForOne  Token0 → Token1 direction
    /// @param amount      Total amount to swap
    /// @param duration    Time over which to spread execution
    function placeLongTermOrder(
        PoolKey calldata key,
        bool    zeroForOne,
        uint256 amount,
        uint256 duration
    ) external whenNotPaused returns (bytes32 orderId) {
        require(duration >= MIN_ORDER_DURATION, "Duration too short");
        require(duration <= MAX_ORDER_DURATION, "Duration too long");
        require(amount > 0, "Zero amount");

        // Transfer tokens from trader
        address token = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        orderId = keccak256(abi.encodePacked(
            msg.sender, key.toId(), zeroForOne, amount, block.timestamp
        ));

        orders[orderId] = LongTermOrder({
            trader:           msg.sender,
            poolId:           key.toId(),
            zeroForOne:       zeroForOne,
            totalAmount:      amount,
            amountRemaining:  amount,
            startTime:        block.timestamp,
            endTime:          block.timestamp + duration,
            lastExecutedTime: block.timestamp,
            active:           true
        });

        poolOrders[key.toId()].push(orderId);

        emit LongTermOrderPlaced(orderId, msg.sender, amount, duration);
    }

    /// @notice Cancel a pending long-term order and refund remaining tokens
    function cancelOrder(PoolKey calldata key, bytes32 orderId) external whenNotPaused {
        LongTermOrder storage order = orders[orderId];
        require(order.trader == msg.sender, "Not order owner");
        require(order.active, "Order not active");

        uint256 refund = order.amountRemaining;
        order.active = false;
        order.amountRemaining = 0;

        address token = order.zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(token).transfer(msg.sender, refund);

        emit LongTermOrderCancelled(orderId, msg.sender, refund);
    }

    // ─── Hook Callback ────────────────────────────────────────────

    /// @notice afterSwap — execute pending virtual swap fractions for this pool
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager whenNotPaused returns (bytes4, int128) {
        PoolId poolId = key.toId();
        _executePendingOrders(poolId, key);
        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Internal Execution ───────────────────────────────────────

    function _executePendingOrders(PoolId poolId, PoolKey calldata key) internal {
        bytes32[] storage orderIds = poolOrders[poolId];
        uint256 totalVirtual0 = 0;
        uint256 totalVirtual1 = 0;

        for (uint256 i = 0; i < orderIds.length; i++) {
            LongTermOrder storage order = orders[orderIds[i]];
            if (!order.active || order.amountRemaining == 0) continue;
            if (block.timestamp > order.endTime) {
                order.active = false;
                continue;
            }

            // How much to execute this block = proportional to elapsed time
            uint256 elapsed = block.timestamp - order.lastExecutedTime;
            uint256 totalDuration = order.endTime - order.startTime;
            if (totalDuration == 0) continue;

            uint256 portion = (order.totalAmount * elapsed) / totalDuration;
            if (portion > order.amountRemaining) portion = order.amountRemaining;
            if (portion == 0) continue;

            order.amountRemaining    -= portion;
            order.lastExecutedTime    = block.timestamp;

            if (order.zeroForOne) totalVirtual0 += portion;
            else                  totalVirtual1 += portion;

            emit LongTermOrderExecuted(orderIds[i], portion, order.amountRemaining);
        }

        // In production: submit these as virtual swaps through PoolManager
        // using flash accounting. The net result aggregates all concurrent TWAMM
        // orders into one efficient execution.
        // Here we emit the event so keepers can observe and batch-settle.
        if (totalVirtual0 > 0 || totalVirtual1 > 0) {
            swapAccumulators[poolId].pendingAmount0 += totalVirtual0;
            swapAccumulators[poolId].pendingAmount1 += totalVirtual1;
            swapAccumulators[poolId].lastExecuted   = block.timestamp;
            emit VirtualSwapExecuted(poolId, totalVirtual0, totalVirtual1);
        }
    }

    // ─── View ─────────────────────────────────────────────────────

    function getOrderProgress(bytes32 orderId)
        external view returns (uint256 pctComplete, uint256 remaining, bool active)
    {
        LongTermOrder storage o = orders[orderId];
        active      = o.active;
        remaining   = o.amountRemaining;
        pctComplete = o.totalAmount > 0
            ? ((o.totalAmount - o.amountRemaining) * 10_000) / o.totalAmount
            : 0;
    }

    function getActiveOrderCount(PoolId poolId) external view returns (uint256 count) {
        bytes32[] storage ids = poolOrders[poolId];
        for (uint256 i = 0; i < ids.length; i++) {
            if (orders[ids[i]].active) count++;
        }
    }

    // ─── IHooks stubs ─────────────────────────────────────────────
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) { revert(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) { revert(); }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure returns (bytes4, BalanceDelta) { revert(); }
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external pure returns (bytes4, BeforeSwapDelta, uint24) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) { revert(); }

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }
}
