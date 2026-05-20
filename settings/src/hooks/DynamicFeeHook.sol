// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Dynamic Fee Hook
//
// Hook #1 (MVP — deploy this FIRST before any other hook)
//
// This hook attaches to a Uniswap v4 pool and dynamically adjusts
// the swap fee based on:
//   1. Real-time on-chain volatility  (TWAP tick ring buffer — PRIMARY)
//   2. AI/ML oracle volatility        (fallback #1)
//   3. Chainlink staleness guard      (fallback #2 — conservative high vol if stale)
//   4. Swap size relative to pool TVL (size premium)
//   5. MEV pattern detection via TWAP deviation + size ratio (arb tax → LP insurance)
//
// Permissions required (bit pattern):
//   beforeSwap (bit 7) = 1
//   afterSwap  (bit 6) = 1  ← for MEV capture routing to insurance fund
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
import {IXenorizeOracle, AggregatorV3Interface, IInsuranceFund} from "../interfaces/IXenorize.sol";

/// @title XenorizeDynamicFeeHook
/// @notice Uniswap v4 hook that adapts swap fees based on real-time market conditions
/// @dev Must be deployed to an address where bits 7 & 6 of the last 2 bytes are set
contract XenorizeDynamicFeeHook {

    using XenorizeMath for uint256;

    // ─── CONSTANTS ───────────────────────────────────────────────
    uint8   public constant MAX_OBSERVATIONS  = 24;         // Ring buffer depth (24 slots)
    uint256 public constant TIMELOCK_DELAY    = 48 hours;

    // ─── IMMUTABLES (set once in constructor) ────────────────────
    address public immutable poolManager;    // Uniswap v4 PoolManager
    address public immutable owner;          // Protocol owner (multisig)
    address public immutable feeRecipient;   // Where protocol fees go

    // ─── STATE ───────────────────────────────────────────────────
    IXenorizeOracle public oracle;           // AI/ML + price oracle
    AggregatorV3Interface public ethUsdFeed; // Chainlink ETH/USD
    address public insuranceFund;            // [P4] IL Insurance Fund — receives MEV premium

    // Per-pool state
    mapping(bytes32 => XenorizeTypes.FeeState)          public poolFeeState;
    mapping(bytes32 => uint256)                          public poolTVLUSD;
    mapping(bytes32 => XenorizeTypes.ObservationBuffer)  private observations;  // [P1] TWAP ring buffer
    mapping(bytes32 => XenorizeTypes.PoolConfig)         public poolConfig;      // [P5] Per-pool config

    // [P2] Authorized callers for updatePoolTVL (e.g. AutoCompounder contracts)
    mapping(address => bool) public authorizedUpdaters;

    // Global defaults — overridden per-pool via poolConfig
    uint24  public baseFee          = 30;      // 0.30%
    uint256 public targetVolBps     = 3_000;   // 30% annualized = "calm market"
    uint256 public oracleMaxAge     = 1 hours; // Stale oracle threshold
    uint256 public mevThresholdBps  = 50;      // 0.5% tick deviation = potential MEV

    // Timelock for governance changes
    mapping(bytes32 => uint256) public pendingChanges; // paramHash → executeTime

    // Emergency pause
    bool public paused;

    // ─── EVENTS ──────────────────────────────────────────────────
    event FeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee);
    event MEVDetected(bytes32 indexed poolId, address indexed swapper, uint256 premiumBps);
    event MEVPremiumCaptured(bytes32 indexed poolId, uint256 premiumBps);      // [P4]
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event InsuranceFundSet(address indexed oldFund, address indexed newFund);  // [P4]
    event ParameterQueued(bytes32 indexed paramHash, uint256 executeTime);
    event EmergencyPause(bool paused);
    event TVLUpdated(bytes32 indexed poolId, uint256 tvlUSD);                  // [P2]
    event PoolConfigSet(bytes32 indexed poolId, uint24 baseFee, uint256 targetVolBps, uint256 mevThresholdBps); // [P5]
    event UpdaterChanged(address indexed updater, bool authorized);            // [P2]

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
        if (_poolManager == address(0))  revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_owner == address(0))        revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_feeRecipient == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();

        poolManager  = _poolManager;
        owner        = _owner;
        feeRecipient = _feeRecipient;
        oracle       = IXenorizeOracle(_oracle);
        ethUsdFeed   = AggregatorV3Interface(_ethUsdFeed);
    }

    // ─── HOOK PERMISSIONS ────────────────────────────────────────

    /// @notice Return which hook callbacks this contract implements
    /// @dev In production this returns a Hooks.Permissions struct
    ///      Bit 7 (beforeSwap) + Bit 6 (afterSwap) must be set
    function getHookPermissions() external pure returns (uint256 permissions) {
        permissions = (1 << 7) | (1 << 6);
    }

    // ─── HOOK CALLBACKS ──────────────────────────────────────────

    /// @notice Called by PoolManager BEFORE each swap
    /// @dev In production: function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    ///      returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride)
    /// @param poolId       The pool being swapped in
    /// @param swapper      Address initiating the swap
    /// @param swapAmountUSD Estimated USD value of swap (passed via hookData)
    /// @param currentTick  Current active tick of the pool (from PoolManager.getSlot0)
    /// @return lpFeeOverride The dynamic fee to use for this swap
    function beforeSwap(
        bytes32 poolId,
        address swapper,
        uint256 swapAmountUSD,
        int24   currentTick
    ) external onlyPoolManager whenNotPaused returns (uint24 lpFeeOverride) {

        // ── [P1] Record tick observation into TWAP ring buffer ───
        _recordObservation(poolId, currentTick);

        // ── [P5] Load per-pool config or global defaults ─────────
        (uint24 _baseFee, uint256 _targetVolBps, uint256 _mevThresholdBps) = _getPoolConfig(poolId);

        // ── [P1] Compute real-time volatility from on-chain TWAP ─
        uint256 currentVol = _getVolatility(poolId, _targetVolBps);

        // ── [P3] Detect MEV via TWAP deviation + size ratio ──────
        (bool mevDetected, uint256 deviationBps) = _detectMEV(
            poolId, swapAmountUSD, currentTick, _mevThresholdBps
        );

        // ── [P6] Compute dynamic MEV premium (proportional) ──────
        // Base 50 BPS + 1 BPS per 10 BPS of price deviation, capped at 500 BPS (5%)
        uint256 mevPremiumBps = 0;
        if (mevDetected) {
            mevPremiumBps = 50 + (deviationBps / 10);
            if (mevPremiumBps > 500) mevPremiumBps = 500;
        }

        // ── Compute dynamic fee ───────────────────────────────────
        lpFeeOverride = XenorizeMath.computeDynamicFee(
            _baseFee,
            currentVol,
            _targetVolBps,
            swapAmountUSD,
            poolTVLUSD[poolId],
            mevPremiumBps
        );

        // ── Update pool fee state ─────────────────────────────────
        XenorizeTypes.FeeState storage feeState = poolFeeState[poolId];
        uint24 oldFee = feeState.currentDynamicFee;

        feeState.currentDynamicFee = lpFeeOverride;
        feeState.volatilityIndex   = currentVol;
        feeState.lastFeeUpdate     = block.timestamp;
        feeState.mevPremium        = mevPremiumBps;

        if (lpFeeOverride != oldFee) {
            emit FeeUpdated(poolId, oldFee, lpFeeOverride);
        }
        if (mevDetected) {
            emit MEVDetected(poolId, swapper, mevPremiumBps);
        }
    }

    /// @notice Called by PoolManager AFTER each swap
    /// @dev [P4] Routes MEV premium to IL insurance fund
    ///      In production: function afterSwap(address, PoolKey calldata, SwapParams calldata,
    ///      BalanceDelta, bytes calldata) returns (bytes4, int128)
    ///      Full token amount extraction requires BalanceDelta — wired up in Phase 2
    /// @param poolId The pool where swap occurred
    function afterSwap(bytes32 poolId) external onlyPoolManager whenNotPaused {
        XenorizeTypes.FeeState memory feeState = poolFeeState[poolId];

        if (feeState.mevPremium > 0) {
            emit MEVPremiumCaptured(poolId, feeState.mevPremium);

            // Route to insurance fund if configured
            // Phase 2: extract mevAmount0/mevAmount1 from BalanceDelta, then call:
            // IInsuranceFund(insuranceFund).deposit(mevAmount0, mevAmount1);
            //
            // Framework intentionally in place — actual token routing requires the real
            // v4 afterSwap BalanceDelta parameter (not available in this simplified sig).
            if (address(insuranceFund) != address(0)) {
                // IInsuranceFund(insuranceFund).deposit(mevAmount0, mevAmount1);
            }
        }
    }

    // ─── INTERNAL: TWAP OBSERVATION BUFFER ───────────────────────

    /// @notice Append current tick + timestamp to the pool's ring buffer
    /// @dev Skips if an observation already exists for this exact block (de-dup)
    function _recordObservation(bytes32 poolId, int24 tick) internal {
        XenorizeTypes.ObservationBuffer storage buf = observations[poolId];

        // Skip duplicate within same block
        if (buf.count > 0) {
            uint8 lastIdx = uint8((buf.nextIndex + MAX_OBSERVATIONS - 1) % MAX_OBSERVATIONS);
            if (buf.timestamps[lastIdx] == block.timestamp) return;
        }

        buf.ticks[buf.nextIndex]      = tick;
        buf.timestamps[buf.nextIndex] = block.timestamp;
        buf.nextIndex = uint8((buf.nextIndex + 1) % MAX_OBSERVATIONS);
        if (buf.count < MAX_OBSERVATIONS) buf.count++;
    }

    /// @notice Compute time-weighted average tick (TWAP) from the observation buffer
    /// @dev Each tick is weighted by the time until the next observation (Uniswap v3 style)
    /// @return twapTick  The TWAP tick over the buffered window
    /// @return valid     False if fewer than 2 observations exist
    function _computeTWAPTick(bytes32 poolId) internal view returns (int24 twapTick, bool valid) {
        XenorizeTypes.ObservationBuffer storage buf = observations[poolId];
        uint8 n = buf.count;
        if (n < 2) return (0, false);

        uint8 start = uint8((buf.nextIndex + MAX_OBSERVATIONS - n) % MAX_OBSERVATIONS);

        int256  sumTickWeighted = 0;
        uint256 totalTime       = 0;

        for (uint8 i = 0; i < n - 1; i++) {
            uint8 cur  = uint8((start + i)     % MAX_OBSERVATIONS);
            uint8 next = uint8((start + i + 1) % MAX_OBSERVATIONS);

            uint256 dt = buf.timestamps[next] - buf.timestamps[cur];
            sumTickWeighted += int256(buf.ticks[cur]) * int256(dt);
            totalTime += dt;
        }

        if (totalTime == 0) return (0, false);
        twapTick = int24(sumTickWeighted / int256(totalTime));
        valid = true;
    }

    /// @notice Compute annualized realized volatility from buffered tick observations
    /// @dev See XenorizeMath.computeRealizedVolatility for the derivation
    /// @return volBps  Annualized vol in BPS (e.g. 3000 = 30%)
    /// @return valid   False if fewer than 2 observations or zero window duration
    function _computeRealizedVol(bytes32 poolId) internal view returns (uint256 volBps, bool valid) {
        XenorizeTypes.ObservationBuffer storage buf = observations[poolId];
        uint8 n = buf.count;
        if (n < 2) return (0, false);

        uint8 start    = uint8((buf.nextIndex + MAX_OBSERVATIONS - n) % MAX_OBSERVATIONS);
        uint8 lastIdx  = uint8((start + n - 1) % MAX_OBSERVATIONS);

        uint256 windowDuration = buf.timestamps[lastIdx] - buf.timestamps[start];
        if (windowDuration == 0) return (0, false);

        uint256 sumSqDiffs = 0;
        int24   prevTick   = buf.ticks[start];

        for (uint8 i = 1; i < n; i++) {
            uint8 idx    = uint8((start + i) % MAX_OBSERVATIONS);
            int24  tick  = buf.ticks[idx];
            int256 diff  = int256(tick) - int256(prevTick);
            sumSqDiffs  += uint256(diff * diff);
            prevTick     = tick;
        }

        volBps = XenorizeMath.computeRealizedVolatility(sumSqDiffs, n - 1, windowDuration);
        valid  = volBps > 0;
    }

    // ─── INTERNAL: VOLATILITY SOURCE PRIORITY ────────────────────

    /// @notice Get current volatility with source priority cascade
    /// @dev Priority: on-chain TWAP realized vol → AI oracle → Chainlink staleness guard → fallback
    function _getVolatility(bytes32 poolId, uint256 _targetVolBps) internal view returns (uint256 volBps) {
        // [P1] Priority 1: on-chain realized vol from TWAP buffer (most real-time)
        (uint256 realizedVol, bool hasRealizedVol) = _computeRealizedVol(poolId);
        if (hasRealizedVol) return realizedVol;

        // Priority 2: AI oracle signal (off-chain, trusted when buffer not yet warm)
        if (address(oracle) != address(0)) {
            try oracle.getVolatility(poolId) returns (uint256 aiVol) {
                if (aiVol > 0) return aiVol;
            } catch {}
        }

        // Priority 3: Chainlink staleness check — conservative high vol if feed is stale
        if (address(ethUsdFeed) != address(0)) {
            (,, , uint256 updatedAt,) = ethUsdFeed.latestRoundData();
            if (block.timestamp - updatedAt > oracleMaxAge) {
                return 5_000; // 50% vol — conservative assumption on stale feed
            }
        }

        // Ultimate fallback: pool target vol (neutral assumption)
        return _targetVolBps;
    }

    // ─── INTERNAL: MEV DETECTION ─────────────────────────────────

    /// @notice Detect MEV using TWAP price deviation + large-swap size heuristic
    /// @dev [P3] Two independent signals — either triggers MEV flag:
    ///      1. currentTick vs TWAP tick: arb pushes pool far from time-avg price
    ///      2. swapSize > 10× mevThreshold% of TVL: likely large arb block
    /// @return isMEV       True if either MEV signal fires
    /// @return deviationBps Tick deviation from TWAP in BPS (used to size the premium)
    function _detectMEV(
        bytes32 poolId,
        uint256 swapAmountUSD,
        int24   currentTick,
        uint256 _mevThresholdBps
    ) internal view returns (bool isMEV, uint256 deviationBps) {

        // Signal 1: TWAP price deviation (primary — works for any pool, no external oracle)
        bool priceMEV = false;
        (int24 twapTick, bool hasTWAP) = _computeTWAPTick(poolId);
        if (hasTWAP) {
            int256 tickDev = int256(currentTick) - int256(twapTick);
            if (tickDev < 0) tickDev = -tickDev;
            // 1 tick ≈ 1 BPS (0.01% price move), so tick deviation ≈ price deviation in BPS
            deviationBps = uint256(tickDev);
            priceMEV = deviationBps > _mevThresholdBps;
        }

        // Signal 2: Swap size relative to pool TVL (secondary heuristic)
        bool sizeMEV = false;
        if (poolTVLUSD[poolId] > 0) {
            uint256 sizeRatioBps = (swapAmountUSD * XenorizeMath.BPS_MAX) / poolTVLUSD[poolId];
            sizeMEV = sizeRatioBps > _mevThresholdBps * 10; // 10× threshold = high confidence
        }

        isMEV = priceMEV || sizeMEV;
    }

    // ─── INTERNAL: CONFIG HELPER ─────────────────────────────────

    /// @notice Return per-pool config if initialized, otherwise global defaults
    function _getPoolConfig(bytes32 poolId) internal view returns (
        uint24 _baseFee, uint256 _targetVolBps, uint256 _mevThresholdBps
    ) {
        XenorizeTypes.PoolConfig storage cfg = poolConfig[poolId];
        if (cfg.initialized) {
            return (cfg.baseFee, cfg.targetVolBps, cfg.mevThresholdBps);
        }
        return (baseFee, targetVolBps, mevThresholdBps);
    }

    // ─── GOVERNANCE (TIMELOCK PROTECTED) ─────────────────────────

    /// @notice Queue an update to the oracle address (48h timelock)
    function queueOracleUpdate(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        bytes32 paramHash = keccak256(abi.encode("oracle", newOracle));
        uint256 executeTime = block.timestamp + TIMELOCK_DELAY;
        pendingChanges[paramHash] = executeTime;
        emit ParameterQueued(paramHash, executeTime);
    }

    /// @notice Execute a queued oracle update after timelock elapses
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

    // ─── GOVERNANCE (OWNER ONLY) ──────────────────────────────────

    /// @notice [P5] Set per-pool fee configuration — overrides global defaults for this pool
    /// @param poolId           The pool to configure
    /// @param _baseFee         Pool-specific base fee in BPS
    /// @param _targetVolBps    Pool-specific calm-market vol target (e.g. 500 for stablecoin pool)
    /// @param _mevThresholdBps Pool-specific MEV detection threshold
    function setPoolConfig(
        bytes32 poolId,
        uint24  _baseFee,
        uint256 _targetVolBps,
        uint256 _mevThresholdBps
    ) external onlyOwner {
        poolConfig[poolId] = XenorizeTypes.PoolConfig({
            baseFee:          _baseFee,
            targetVolBps:     _targetVolBps,
            mevThresholdBps:  _mevThresholdBps,
            initialized:      true
        });
        emit PoolConfigSet(poolId, _baseFee, _targetVolBps, _mevThresholdBps);
    }

    /// @notice [P4] Set the IL insurance fund address that receives MEV premium
    function setInsuranceFund(address _fund) external onlyOwner {
        if (_fund == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        address old = insuranceFund;
        insuranceFund = _fund;
        emit InsuranceFundSet(old, _fund);
    }

    /// @notice [P2] Grant or revoke TVL update permission for a caller (e.g. AutoCompounder)
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        if (updater == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        authorizedUpdaters[updater] = authorized;
        emit UpdaterChanged(updater, authorized);
    }

    /// @notice [P2] Update pool TVL — restricted to owner or authorized updaters only
    /// @dev In production: derive from PoolManager.getPool() state directly
    function updatePoolTVL(bytes32 poolId, uint256 tvlUSD) external {
        if (msg.sender != owner && !authorizedUpdaters[msg.sender]) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, owner);
        }
        poolTVLUSD[poolId] = tvlUSD;
        emit TVLUpdated(poolId, tvlUSD);
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

    /// @notice Preview what fee a hypothetical swap would receive
    /// @param mevDetected Pass true to simulate MEV scenario (uses 50 BPS base estimate)
    function previewFee(
        bytes32 poolId,
        uint256 swapAmountUSD,
        bool    mevDetected
    ) external view returns (uint24 fee) {
        (uint24 _baseFee, uint256 _targetVolBps,) = _getPoolConfig(poolId);
        uint256 vol = _getVolatility(poolId, _targetVolBps);
        fee = XenorizeMath.computeDynamicFee(
            _baseFee,
            vol,
            _targetVolBps,
            swapAmountUSD,
            poolTVLUSD[poolId],
            mevDetected ? 50 : 0  // Conservative 50 BPS estimate for preview
        );
    }

    /// @notice Get current TWAP tick for a pool (useful for monitoring)
    function getTWAPTick(bytes32 poolId) external view returns (int24 twapTick, bool valid) {
        return _computeTWAPTick(poolId);
    }

    /// @notice Get current on-chain realized volatility for a pool
    function getRealizedVolatility(bytes32 poolId) external view returns (uint256 volBps, bool valid) {
        return _computeRealizedVol(poolId);
    }

    /// @notice How many valid observations are in the ring buffer for a pool
    function getObservationCount(bytes32 poolId) external view returns (uint8) {
        return observations[poolId].count;
    }
}
