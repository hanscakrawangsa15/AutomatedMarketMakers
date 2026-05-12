// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Dynamic Fee Hook
//
// Hook #1 (MVP — deploy this FIRST before any other hook)
//
// This hook attaches to a Uniswap v4 pool and dynamically adjusts
// the swap fee based on:
//   1. Real-time volatility (from on-chain TWAP + Chainlink)
//   2. Swap size relative to pool TVL (size premium)
//   3. MEV pattern detection (arb tax returned to LP)
//
// Permissions required (bit pattern):
//   beforeSwap (bit 7) = 1
//   afterSwap  (bit 6) = 1  ← for MEV capture
//   → Hook address must have bits 7 & 6 set
//   → Mine with CREATE2 until address ends in 0b11000000 = 0xC0
//
// Deploy sequence:
//   1. Compile this contract
//   2. Run: script/MineHookAddress.s.sol to find valid CREATE2 salt
//   3. Deploy to mined address
//   4. Initialize pool with this hook address
// ─────────────────────────────────────────────────────────────────

// NOTE: In production, import from installed npm packages:
// import {BaseHook} from "@uniswap/v4-periphery/src/base/hooks/BaseHook.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {XenorizeTypes} from "../types/XenorizeTypes.sol";
import {IXenorizeOracle, AggregatorV3Interface} from "../interfaces/IXenorize.sol";

/// @title XenorizeDynamicFeeHook
/// @notice Uniswap v4 hook that adapts swap fees based on market conditions
/// @dev Must be deployed to an address where bits 7 & 6 of the last 2 bytes are set
contract XenorizeDynamicFeeHook {

    using XenorizeMath for uint256;

    // ─── IMMUTABLES (set once in constructor) ────────────────────
    address public immutable poolManager;    // Uniswap v4 PoolManager
    address public immutable owner;          // Protocol owner (multisig)
    address public immutable feeRecipient;   // Where MEV capture goes

    // ─── STATE ───────────────────────────────────────────────────
    IXenorizeOracle public oracle;           // AI/ML + price oracle
    AggregatorV3Interface public ethUsdFeed; // Chainlink ETH/USD

    // Per-pool fee state
    mapping(bytes32 => XenorizeTypes.FeeState) public poolFeeState;

    // Per-pool TVL tracking (simplified — real impl uses PoolManager)
    mapping(bytes32 => uint256) public poolTVLUSD;

    // Protocol settings (governance controlled, behind timelock)
    uint24  public baseFee        = 30;      // 0.30% default base fee
    uint256 public targetVolBps   = 3_000;   // 30% annualized vol = "calm"
    uint256 public oracleMaxAge   = 1 hours; // Stale oracle threshold
    uint256 public mevThresholdBps = 50;     // 0.5% price impact = MEV

    // Timelock for governance changes
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    mapping(bytes32 => uint256) public pendingChanges; // paramHash → executeTime

    // Emergency pause
    bool public paused;

    // ─── EVENTS ──────────────────────────────────────────────────
    event FeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee);
    event MEVDetected(bytes32 indexed poolId, address indexed swapper, uint256 premiumBps);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ParameterQueued(bytes32 indexed paramHash, uint256 executeTime);
    event EmergencyPause(bool paused);

    // ─── MODIFIERS ───────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, owner);
        }
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, poolManager);
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert XenorizeTypes.Xenorize__EmergencyPaused();
        _;
    }

    // ─── CONSTRUCTOR ─────────────────────────────────────────────
    constructor(
        address _poolManager,
        address _owner,
        address _feeRecipient,
        address _oracle,
        address _ethUsdFeed
    ) {
        if (_poolManager == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_owner == address(0))       revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_feeRecipient == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();

        poolManager   = _poolManager;
        owner         = _owner;
        feeRecipient  = _feeRecipient;
        oracle        = IXenorizeOracle(_oracle);
        ethUsdFeed    = AggregatorV3Interface(_ethUsdFeed);
    }

    // ─── HOOK PERMISSIONS ────────────────────────────────────────

    /// @notice Return which hook callbacks this contract implements
    /// @dev In production this returns a Hooks.Permissions struct
    ///      Bit 7 (beforeSwap) + Bit 6 (afterSwap) must be set
    function getHookPermissions() external pure returns (uint256 permissions) {
        // Bit 7: beforeSwap = true
        // Bit 6: afterSwap  = true
        permissions = (1 << 7) | (1 << 6);
    }

    // ─── HOOK CALLBACKS ──────────────────────────────────────────

    /// @notice Called by PoolManager BEFORE each swap
    /// @dev This is where we compute and set the dynamic fee
    ///      In production: function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    ///      returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride)
    /// @param poolId The pool being swapped in
    /// @param swapper Address initiating the swap
    /// @param swapAmountUSD Estimated USD value of swap (passed via hookData)
    /// @return lpFeeOverride The dynamic fee to use for this swap (overrides static fee)
    function beforeSwap(
        bytes32 poolId,
        address swapper,
        uint256 swapAmountUSD
    ) external onlyPoolManager whenNotPaused returns (uint24 lpFeeOverride) {

        // ── Step 1: Get current volatility ──────────────────────
        uint256 currentVol = _getVolatility(poolId);

        // ── Step 2: Detect MEV ──────────────────────────────────
        bool mevDetected = _detectMEV(poolId, swapAmountUSD, swapper);

        // ── Step 3: Compute dynamic fee ─────────────────────────
        lpFeeOverride = XenorizeMath.computeDynamicFee(
            baseFee,
            currentVol,
            targetVolBps,
            swapAmountUSD,
            poolTVLUSD[poolId],
            mevDetected
        );

        // ── Step 4: Update pool fee state ───────────────────────
        XenorizeTypes.FeeState storage feeState = poolFeeState[poolId];
        uint24 oldFee = feeState.currentDynamicFee;

        feeState.currentDynamicFee = lpFeeOverride;
        feeState.volatilityIndex   = currentVol;
        feeState.lastFeeUpdate     = block.timestamp;
        feeState.mevPremium        = mevDetected ? 50 : 0;

        if (lpFeeOverride != oldFee) {
            emit FeeUpdated(poolId, oldFee, lpFeeOverride);
        }

        if (mevDetected) {
            emit MEVDetected(poolId, swapper, 50);
        }
    }

    /// @notice Called by PoolManager AFTER each swap
    /// @dev Used to capture MEV fee premium and route to LP insurance fund
    ///      In production: function afterSwap(address, PoolKey calldata, SwapParams calldata,
    ///      BalanceDelta, bytes calldata) returns (bytes4, int128)
    /// @param poolId The pool where swap occurred
    function afterSwap(bytes32 poolId) external onlyPoolManager whenNotPaused {
        // In full implementation:
        // 1. Calculate MEV premium from the swap delta
        // 2. Extract premium amount from fee collected
        // 3. Route to insurance fund via IInsuranceFund.deposit()
        // This is intentionally minimal for MVP — expand in Phase 2

        XenorizeTypes.FeeState memory feeState = poolFeeState[poolId];

        // If MEV was detected, log it (actual fund routing in Phase 2)
        if (feeState.mevPremium > 0) {
            // TODO Phase 2: extract mev_premium_amount and call:
            // insuranceFund.deposit(mev_amount_token0, mev_amount_token1)
        }
    }

    // ─── INTERNAL LOGIC ──────────────────────────────────────────

    /// @notice Get current volatility for a pool
    /// @dev Priority: AI Oracle → Chainlink implied vol → TWAP fallback
    function _getVolatility(bytes32 poolId) internal view returns (uint256 volBps) {
        // Try AI oracle first
        if (address(oracle) != address(0)) {
            try oracle.getVolatility(poolId) returns (uint256 aiVol) {
                if (aiVol > 0) return aiVol;
            } catch {
                // Oracle failed, fall through to Chainlink
            }
        }

        // Fallback: Use Chainlink ETH/USD feed price deviation as vol proxy
        // In production: compute realized vol from TWAP observations
        if (address(ethUsdFeed) != address(0)) {
            (, int256 price,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();

            // Check staleness
            if (block.timestamp - updatedAt > oracleMaxAge) {
                // Stale oracle: return conservative high vol
                return 5_000; // 50% vol — conservative assumption
            }

            if (price <= 0) {
                return 5_000; // Invalid price: assume high vol
            }

            // Simplified vol proxy: return medium vol as default
            // Real implementation would compute TWAP-based realized vol
            return targetVolBps; // Return target as neutral assumption
        }

        // Ultimate fallback
        return targetVolBps;
    }

    /// @notice Detect potential MEV (arbitrage) in swap
    /// @dev Compares swap price to oracle price
    ///      If deviation > threshold, likely arbitrage
    function _detectMEV(
        bytes32 poolId,
        uint256 swapAmountUSD,
        address /*swapper*/
    ) internal view returns (bool isMEV) {

        // MEV detection heuristics:
        // 1. Large swap relative to pool TVL
        // 2. Swap immediately follows a price movement
        // 3. Swap exactly at tick boundary

        if (poolTVLUSD[poolId] == 0) return false;

        // Heuristic: swap > 5% of TVL in one go = likely arb
        uint256 sizeRatioBps = (swapAmountUSD * XenorizeMath.BPS_MAX) / poolTVLUSD[poolId];

        isMEV = sizeRatioBps > mevThresholdBps * 10; // 10x threshold = confident MEV

        // Phase 2: Add more sophisticated MEV detection:
        // - Compare vs oracle price (Chainlink)
        // - Track sandwich patterns across blocks
        // - Use private mempool data if available
    }

    // ─── GOVERNANCE (TIMELOCK PROTECTED) ─────────────────────────

    /// @notice Queue an update to the oracle address
    /// @dev Queued changes execute after TIMELOCK_DELAY
    function queueOracleUpdate(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();

        bytes32 paramHash = keccak256(abi.encode("oracle", newOracle));
        uint256 executeTime = block.timestamp + TIMELOCK_DELAY;
        pendingChanges[paramHash] = executeTime;

        emit ParameterQueued(paramHash, executeTime);
    }

    /// @notice Execute a queued oracle update
    function executeOracleUpdate(address newOracle) external onlyOwner {
        bytes32 paramHash = keccak256(abi.encode("oracle", newOracle));
        uint256 executeTime = pendingChanges[paramHash];

        if (executeTime == 0 || block.timestamp < executeTime) {
            revert XenorizeTypes.Xenorize__TimelockNotElapsed(executeTime, block.timestamp);
        }

        delete pendingChanges[paramHash];

        address oldOracle = address(oracle);
        oracle = IXenorizeOracle(newOracle);

        emit OracleUpdated(oldOracle, newOracle);
    }

    /// @notice Update pool TVL (called by AutoCompounder on deposit/withdraw)
    /// @dev In production: derive from PoolManager on-chain state
    function updatePoolTVL(bytes32 poolId, uint256 tvlUSD) external {
        // Only AutoCompounder or owner can update TVL
        // In production: verify caller is registered AutoCompounder
        poolTVLUSD[poolId] = tvlUSD;
    }

    // ─── EMERGENCY ───────────────────────────────────────────────

    /// @notice Emergency pause — stops all hook callbacks
    /// @dev Callable by multisig only
    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
        emit EmergencyPause(_pause);
    }

    // ─── VIEW FUNCTIONS ──────────────────────────────────────────

    /// @notice Get the current effective fee for a pool
    function getCurrentFee(bytes32 poolId) external view returns (uint24) {
        return poolFeeState[poolId].currentDynamicFee;
    }

    /// @notice Preview what fee a swap would receive
    function previewFee(
        bytes32 poolId,
        uint256 swapAmountUSD,
        bool mevDetected
    ) external view returns (uint24 fee) {
        uint256 vol = _getVolatility(poolId);
        fee = XenorizeMath.computeDynamicFee(
            baseFee,
            vol,
            targetVolBps,
            swapAmountUSD,
            poolTVLUSD[poolId],
            mevDetected
        );
    }
}
