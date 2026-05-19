// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Uniswap V4 ───────────────────────────────────────────────────
import {IHooks}       from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}      from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks}        from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency}     from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// ─── Xenorize ─────────────────────────────────────────────────────
import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {PositionSnapshot, InsuranceClaim} from "../types/XenorizeTypes.sol";
import {IInsuranceFund, IXenorizeOracle, IILShieldHook} from "../interfaces/IXenorize.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__Unauthorized,
    Xenorize__EmergencyPaused
} from "../types/XenorizeTypes.sol";

/**
 * @title XenorizeILShieldHook
 * @notice Uniswap V4 hook that tracks LP positions and compensates for Impermanent Loss
 *         when liquidity is removed.
 *
 * Flow:
 *   afterAddLiquidity  → record/update PositionSnapshot (entry price, amounts, liquidity)
 *   afterRemoveLiquidity → calculate IL vs HODL, compute loyalty score, submit claim
 *
 * Hook address bits required: AFTER_ADD_LIQUIDITY (bit 10) | AFTER_REMOVE_LIQUIDITY (bit 8)
 * Address lower-14-bit mask: 0x0500
 *
 * Deployment note: Use CREATE2 / HookMiner to find a salt that produces an address whose
 * lower 14 bits equal 0x0500. Call validateHookAddress() post-deploy to verify.
 *
 * hookData convention: abi.encode(address lpOwner) — pass the actual LP's address when
 * the caller is a router/manager rather than the LP directly.
 */
contract XenorizeILShieldHook is IHooks, IILShieldHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // ─── Constants ────────────────────────────────────────────────
    uint256 private constant WAD = 1e18;

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager   public immutable poolManager;
    IInsuranceFund public immutable insuranceFund;
    IXenorizeOracle public immutable oracle;
    address        public immutable owner;

    // ─── Storage ──────────────────────────────────────────────────
    /// snapshotKey = keccak256(lpOwner, poolId, tickLower, tickUpper)
    mapping(bytes32 => PositionSnapshot) public snapshots;

    bool public paused;

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager))
            revert Xenorize__Unauthorized(msg.sender, address(poolManager));
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert Xenorize__EmergencyPaused();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────
    constructor(
        IPoolManager   _poolManager,
        IInsuranceFund _insuranceFund,
        IXenorizeOracle _oracle,
        address        _owner
    ) {
        if (address(_poolManager) == address(0) || address(_insuranceFund) == address(0))
            revert Xenorize__ZeroAddress();
        poolManager   = _poolManager;
        insuranceFund = _insuranceFund;
        oracle        = _oracle;
        owner         = _owner;
    }

    // ─── Hook Permissions ─────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               true,   // ← record snapshot
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            true,   // ← calculate IL + submit claim
            beforeSwap:                      false,
            afterSwap:                       false,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Verifies that this contract is deployed at an address with the correct hook bits.
    function validateHookAddress() external view returns (bool) {
        uint160 addr  = uint160(address(this));
        uint160 mask  = (1 << 14) - 1;
        uint160 flags = (1 << 10) | (1 << 8); // AFTER_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY
        return addr & mask == flags;
    }

    // ─── Hook: afterAddLiquidity ───────────────────────────────────

    /**
     * @notice Called by PoolManager after LP adds liquidity.
     *         Creates or updates a position snapshot used later to compute IL.
     * @param sender    Address that called poolManager.unlock() (may be a router)
     * @param key       Pool key
     * @param params    Liquidity modification params (tickLower, tickUpper, liquidityDelta)
     * @param delta     Token amounts actually moved (negative = LP paid the pool)
     * @param hookData  Optional abi.encode(address lpOwner) for router-based flows
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta /* feesAccrued */,
        bytes calldata hookData
    ) external override onlyPoolManager whenNotPaused returns (bytes4, BalanceDelta) {
        // Only handle actual liquidity additions (not fee collection at liquidityDelta == 0)
        if (params.liquidityDelta <= 0) {
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        address lpOwner = _decodeLPOwner(hookData, sender);
        bytes32 key_    = _snapshotKey(lpOwner, key.toId(), params.tickLower, params.tickUpper);

        // Tokens LP deposited: delta.amount() is negative (LP paid into pool)
        uint256 deposited0 = delta.amount0() < 0 ? uint128(-delta.amount0()) : 0;
        uint256 deposited1 = delta.amount1() < 0 ? uint128(-delta.amount1()) : 0;

        uint128 newLiquidity = uint128(uint256(params.liquidityDelta));

        (uint256 price0, uint256 price1) = _getPrices(key);

        PositionSnapshot storage snap = snapshots[key_];

        if (!snap.exists) {
            // First deposit → create snapshot
            snap.amount0     = deposited0;
            snap.amount1     = deposited1;
            snap.price0USD   = price0;
            snap.price1USD   = price1;
            snap.depositTime = block.timestamp;
            snap.liquidity   = newLiquidity;
            snap.exists      = true;

            emit SnapshotCreated(key_, lpOwner, price0, price1);
        } else {
            // Additional deposit to same range → liquidity-weighted average entry price
            uint256 oldLiq = uint256(snap.liquidity);
            uint256 addLiq = uint256(newLiquidity);
            uint256 totLiq = oldLiq + addLiq;

            snap.price0USD = (snap.price0USD * oldLiq + price0 * addLiq) / totLiq;
            snap.price1USD = (snap.price1USD * oldLiq + price1 * addLiq) / totLiq;
            snap.amount0  += deposited0;
            snap.amount1  += deposited1;
            snap.liquidity = uint128(totLiq);

            emit SnapshotUpdated(key_, lpOwner, snap.price0USD, snap.price1USD);
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ─── Hook: afterRemoveLiquidity ───────────────────────────────

    /**
     * @notice Called by PoolManager after LP removes liquidity.
     *         Computes IL versus a HODL baseline and submits a compensation claim.
     * @param sender    Address that called poolManager.unlock()
     * @param key       Pool key
     * @param params    Liquidity modification params (liquidityDelta is negative for removal)
     * @param delta     Tokens returned to LP (positive values)
     * @param hookData  Optional abi.encode(address lpOwner)
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta /* feesAccrued */,
        bytes calldata hookData
    ) external override onlyPoolManager whenNotPaused returns (bytes4, BalanceDelta) {
        address lpOwner = _decodeLPOwner(hookData, sender);
        bytes32 key_    = _snapshotKey(lpOwner, key.toId(), params.tickLower, params.tickUpper);

        PositionSnapshot storage snap = snapshots[key_];
        if (!snap.exists) {
            emit ILSkipped(key_, "No snapshot");
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Tokens LP received back (positive delta)
        uint256 returned0 = delta.amount0() > 0 ? uint128(delta.amount0()) : 0;
        uint256 returned1 = delta.amount1() > 0 ? uint128(delta.amount1()) : 0;

        // Fraction of position being removed (WAD-scaled)
        // liquidityDelta is negative for removal; negate and convert safely via uint256
        uint256 removedLiq = params.liquidityDelta < 0
            ? uint256(-params.liquidityDelta)
            : 0;
        uint256 totalLiq    = uint256(snap.liquidity);
        uint256 fraction    = totalLiq > 0 ? (removedLiq * WAD) / totalLiq : WAD;

        // Proportional entry amounts for this removal
        uint256 entryAmt0 = (snap.amount0 * fraction) / WAD;
        uint256 entryAmt1 = (snap.amount1 * fraction) / WAD;

        // Current exit prices
        (uint256 price0Exit, uint256 price1Exit) = _getPrices(key);

        // IL in primary asset (token0 units) using XenorizeMath
        // IL = HODL_value_exit - LP_value_exit, expressed in token0
        // IL denominated in USD (18-dec). Fund primary asset is assumed USD-pegged (e.g. USDC).
        uint256 ilUSD = _computeILInUSD(
            entryAmt0,
            entryAmt1,
            returned0,
            returned1,
            price0Exit,
            price1Exit
        );

        // Record deposit time before modifying/deleting the snapshot
        uint256 depositTime = snap.depositTime;

        // Update or clear snapshot
        if (fraction >= WAD || removedLiq >= totalLiq) {
            delete snapshots[key_];
        } else {
            snap.amount0   -= entryAmt0;
            snap.amount1   -= entryAmt1;
            snap.liquidity  = uint128(totalLiq - removedLiq);
        }

        if (ilUSD == 0) {
            emit ILSkipped(key_, "No IL");
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Loyalty score: 0–10_000 BPS (100% after 90 days)
        uint256 loyaltyScore = XenorizeMath.computeLoyaltyScore(depositTime, block.timestamp);

        bytes32 claimId = _snapshotKey(lpOwner, key.toId(), params.tickLower, params.tickUpper);
        InsuranceClaim memory claim = InsuranceClaim({
            positionId:   claimId,
            recipient:    lpOwner,
            ilAmountUSD:  ilUSD,
            loyaltyScore: loyaltyScore,
            proof:        ""
        });

        try insuranceFund.submitClaim(claim) returns (uint256 compensated0, uint256) {
            emit ILCompensationTriggered(key_, lpOwner, ilUSD, compensated0);
        } catch {
            emit ILSkipped(key_, "Fund claim failed");
        }

        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // ─── Admin ────────────────────────────────────────────────────

    function emergencyPause(bool _pause) external onlyOwner {
        paused = _pause;
    }

    // ─── Internal helpers ─────────────────────────────────────────

    function _snapshotKey(
        address lp,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(lp, PoolId.unwrap(poolId), tickLower, tickUpper));
    }

    /// @dev Decode LP owner from hookData; fall back to `sender` if empty.
    function _decodeLPOwner(bytes calldata hookData, address sender)
        internal pure returns (address)
    {
        return hookData.length >= 32 ? abi.decode(hookData, (address)) : sender;
    }

    /// @dev Fetch token0 and token1 USD prices from oracle; fall back to 1 USD if unavailable.
    function _getPrices(PoolKey calldata key)
        internal view returns (uint256 price0, uint256 price1)
    {
        if (address(oracle) == address(0)) return (WAD, WAD);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        try oracle.getTokenPriceUSD(token0) returns (uint256 p, uint256) {
            price0 = p > 0 ? p : WAD;
        } catch { price0 = WAD; }

        try oracle.getTokenPriceUSD(token1) returns (uint256 p, uint256) {
            price1 = p > 0 ? p : WAD;
        } catch { price1 = WAD; }
    }

    /**
     * @dev Compute IL in 18-decimal USD.
     *
     *   HODL_exit = entryAmt0 × price0Exit  +  entryAmt1 × price1Exit
     *   LP_exit   = returned0  × price0Exit  +  returned1  × price1Exit
     *   IL_usd    = max(0, HODL_exit - LP_exit)
     *
     * The fund pays in its primary asset (assumed USD-pegged, e.g. USDC).
     * 1 USD ≈ 1 primary asset token, so ilAmountUSD maps directly to fund tokens.
     */
    function _computeILInUSD(
        uint256 entryAmt0,
        uint256 entryAmt1,
        uint256 returned0,
        uint256 returned1,
        uint256 price0Exit,
        uint256 price1Exit
    ) internal pure returns (uint256 ilUSD) {
        uint256 hodlUSD = (entryAmt0 * price0Exit) / WAD + (entryAmt1 * price1Exit) / WAD;
        uint256 lpUSD   = (returned0  * price0Exit) / WAD + (returned1  * price1Exit) / WAD;
        ilUSD = lpUSD >= hodlUSD ? 0 : hodlUSD - lpUSD;
    }

    // ─── Unimplemented IHooks stubs ───────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4) { revert(); }
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4) { revert(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external pure override returns (bytes4, BeforeSwapDelta, uint24) { revert(); }
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, int128) { revert(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert(); }
}
