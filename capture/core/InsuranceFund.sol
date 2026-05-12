// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — IL Insurance Fund
//
// Self-sustaining insurance fund that compensates LPs for
// Impermanent Loss using REAL PROTOCOL REVENUE — not token minting.
//
// Revenue sources:
//   1. MEV captured by DynamicFeeHook (redirected arb fees)
//   2. Dynamic fee premium during high volatility
//   3. Protocol fee (% of all swap fees)
//   4. Early exit penalty from Loyalty Hook
//
// Payout rules:
//   - Max 50% of IL compensated per claim
//   - Loyalty score affects max eligible amount
//   - Claims suspended if fund < MIN_FUND_RATIO of TVL
//   - Per-claim cap to prevent fund drain
//   - Queue system during high demand periods
// ─────────────────────────────────────────────────────────────────

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {XenorizeTypes} from "../types/XenorizeTypes.sol";
import {IInsuranceFund} from "../interfaces/IXenorize.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract XenorizeInsuranceFund is IInsuranceFund, ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;
    using XenorizeMath for uint256;

    // ─── IMMUTABLES ──────────────────────────────────────────────
    address public immutable owner;          // Multisig
    address public immutable autoCompounder; // Only AutoCompounder can submit claims
    IERC20  public immutable token0;         // Primary pool token (e.g., USDC)
    IERC20  public immutable token1;         // Secondary pool token (e.g., WETH)

    // ─── CONSTANTS ───────────────────────────────────────────────
    uint256 public constant MAX_CLAIM_BPS        = 5_000;  // 50% max of IL compensated
    uint256 public constant MIN_FUND_RATIO_BPS   = 500;    // Fund must be ≥ 5% of TVL
    uint256 public constant MAX_SINGLE_CLAIM_USD = 10_000e18; // $10K max per claim
    uint256 public constant CLAIM_COOLDOWN       = 7 days;  // LP can't claim twice in 7d
    uint256 public constant BPS                  = 10_000;

    // ─── STATE ───────────────────────────────────────────────────
    uint256 public fundBalance0;          // Token0 in fund
    uint256 public fundBalance1;          // Token1 in fund
    uint256 public totalPaidOut0;         // All-time token0 payouts
    uint256 public totalPaidOut1;         // All-time token1 payouts
    uint256 public totalDeposited0;       // All-time deposits token0
    uint256 public totalDeposited1;       // All-time deposits token1
    uint256 public totalTVL;             // Protocol TVL estimate (set by AutoCompounder)

    mapping(address => uint256) public lastClaimTime;     // LP → last claim timestamp
    mapping(bytes32 => uint256) public positionClaimed0;  // posId → total claimed token0
    mapping(bytes32 => uint256) public positionClaimed1;  // posId → total claimed token1

    // Authorized depositors (hooks, compounder)
    mapping(address => bool) public authorizedDepositors;

    // ─── EVENTS ──────────────────────────────────────────────────
    event ClaimPaid(
        bytes32 indexed positionId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );
    event FundDeposited(address indexed source, uint256 amount0, uint256 amount1);
    event ClaimsSuspended(string reason);
    event ClaimsResumed();
    event DepositorAuthorized(address indexed depositor, bool authorized);
    event TVLUpdated(uint256 newTVL);

    // ─── MODIFIERS ───────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, owner);
        }
        _;
    }

    modifier onlyAutoCompounder() {
        if (msg.sender != autoCompounder) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, autoCompounder);
        }
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedDepositors[msg.sender] && msg.sender != owner) {
            revert XenorizeTypes.Xenorize__Unauthorized(msg.sender, address(0));
        }
        _;
    }

    // ─── CONSTRUCTOR ─────────────────────────────────────────────
    constructor(
        address _owner,
        address _autoCompounder,
        address _token0,
        address _token1
    ) {
        if (_owner == address(0))         revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_autoCompounder == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_token0 == address(0))        revert XenorizeTypes.Xenorize__ZeroAddress();
        if (_token1 == address(0))        revert XenorizeTypes.Xenorize__ZeroAddress();

        owner          = _owner;
        autoCompounder = _autoCompounder;
        token0         = IERC20(_token0);
        token1         = IERC20(_token1);

        authorizedDepositors[_autoCompounder] = true;
    }

    // ─── CORE: CLAIM PROCESSING ──────────────────────────────────

    /// @notice Submit a claim for IL compensation
    /// @dev Only callable by AutoCompounder on behalf of LP
    ///      Follows Check-Effects-Interactions pattern
    function submitClaim(
        XenorizeTypes.InsuranceClaim calldata claim
    ) external nonReentrant whenNotPaused onlyAutoCompounder
      returns (uint256 compensated0, uint256 compensated1) {

        // ── CHECKS ──────────────────────────────────────────────
        if (paused()) revert XenorizeTypes.Xenorize__ClaimsSuspended();

        // Decode recipient from claim (in production, derive from positionId)
        address recipient = _getPositionOwner(claim.positionId);

        // Cooldown: LP can only claim once per CLAIM_COOLDOWN period
        uint256 lastClaim = lastClaimTime[recipient];
        if (lastClaim > 0 && block.timestamp < lastClaim + CLAIM_COOLDOWN) {
            // Return 0 instead of reverting — claim just not processed
            return (0, 0);
        }

        // Fund health check — suspend if fund is too low
        _checkFundHealth();

        // Calculate max eligible compensation
        (uint256 maxComp0, uint256 maxComp1) = getMaxClaim(
            claim.positionId,
            claim.ilAmount0,
            claim.ilAmount1,
            claim.loyaltyScore
        );

        if (maxComp0 == 0 && maxComp1 == 0) return (0, 0);

        // Actual compensation = min(eligible, available)
        compensated0 = maxComp0 > fundBalance0 ? fundBalance0 : maxComp0;
        compensated1 = maxComp1 > fundBalance1 ? fundBalance1 : maxComp1;

        // ── EFFECTS ─────────────────────────────────────────────
        // Update state BEFORE any external calls
        fundBalance0 -= compensated0;
        fundBalance1 -= compensated1;
        totalPaidOut0 += compensated0;
        totalPaidOut1 += compensated1;
        lastClaimTime[recipient] = block.timestamp;
        positionClaimed0[claim.positionId] += compensated0;
        positionClaimed1[claim.positionId] += compensated1;

        // ── INTERACTIONS ────────────────────────────────────────
        if (compensated0 > 0) {
            token0.safeTransfer(recipient, compensated0);
        }
        if (compensated1 > 0) {
            token1.safeTransfer(recipient, compensated1);
        }

        emit ClaimPaid(claim.positionId, recipient, compensated0, compensated1);
    }

    // ─── CORE: FUND DEPOSITS ─────────────────────────────────────

    /// @notice Deposit revenue into the insurance fund
    /// @dev Called by DynamicFeeHook (MEV capture) and AutoCompounder (protocol fee)
    function deposit(
        uint256 amount0,
        uint256 amount1
    ) external nonReentrant onlyAuthorized {

        if (amount0 == 0 && amount1 == 0) revert XenorizeTypes.Xenorize__ZeroAmount();

        // ── EFFECTS ─────────────────────────────────────────────
        fundBalance0 += amount0;
        fundBalance1 += amount1;
        totalDeposited0 += amount0;
        totalDeposited1 += amount1;

        // ── INTERACTIONS ────────────────────────────────────────
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        emit FundDeposited(msg.sender, amount0, amount1);
    }

    // ─── CLAIM CALCULATION ───────────────────────────────────────

    /// @notice Calculate maximum eligible claim amount
    /// @dev Incorporates: IL cap, loyalty weight, per-claim cap, fund health
    function getMaxClaim(
        bytes32 positionId,
        uint256 ilAmount0,
        uint256 ilAmount1,
        uint256 loyaltyScore // 0 - 10_000
    ) public view returns (uint256 maxToken0, uint256 maxToken1) {

        if (ilAmount0 == 0 && ilAmount1 == 0) return (0, 0);

        // Step 1: Apply max IL compensation cap (50%)
        uint256 capAmount0 = (ilAmount0 * MAX_CLAIM_BPS) / BPS;
        uint256 capAmount1 = (ilAmount1 * MAX_CLAIM_BPS) / BPS;

        // Step 2: Apply loyalty score weight
        // loyaltyScore 0 = 0% of cap, 10_000 = 100% of cap
        uint256 loyaltyAmount0 = (capAmount0 * loyaltyScore) / BPS;
        uint256 loyaltyAmount1 = (capAmount1 * loyaltyScore) / BPS;

        // Step 3: Apply per-claim dollar cap ($10K equivalent)
        // Simplified: use token0 as USD proxy (assumes token0 = stablecoin)
        uint256 remainingCap = MAX_SINGLE_CLAIM_USD > positionClaimed0[positionId]
            ? MAX_SINGLE_CLAIM_USD - positionClaimed0[positionId]
            : 0;

        maxToken0 = loyaltyAmount0 > remainingCap ? remainingCap : loyaltyAmount0;
        maxToken1 = loyaltyAmount1; // Token1 cap applied separately in production

        // Step 4: Fund health multiplier
        // If fund is < 10% of TVL, scale down all claims proportionally
        uint256 healthBps = _getFundHealthBps();
        if (healthBps < 1_000) { // Below 10% health
            maxToken0 = (maxToken0 * healthBps) / BPS;
            maxToken1 = (maxToken1 * healthBps) / BPS;
        }
    }

    // ─── INTERNAL HELPERS ────────────────────────────────────────

    /// @notice Check if fund health is above minimum threshold
    /// @dev Suspends claims and emits event if fund is critically low
    function _checkFundHealth() internal {
        uint256 healthBps = _getFundHealthBps();

        if (healthBps < MIN_FUND_RATIO_BPS) {
            // Fund critically low — suspend new claims
            _pause();
            emit ClaimsSuspended("Fund below minimum ratio");
        }
    }

    /// @notice Get fund health as BPS of TVL
    function _getFundHealthBps() internal view returns (uint256 healthBps) {
        if (totalTVL == 0) return BPS; // No TVL = 100% health (no exposure)

        // Simplified: use token0 balance as fund health proxy
        // Production: convert all balances to USD and compare
        uint256 fundInUSD = fundBalance0; // Assumes token0 = stablecoin
        healthBps = (fundInUSD * BPS) / totalTVL;
    }

    /// @notice Get position owner address from positionId
    /// @dev In production: call AutoCompounder.getPosition(positionId).owner
    function _getPositionOwner(bytes32 positionId) internal view returns (address) {
        // Simplified for now — production implementation queries AutoCompounder
        // This prevents unauthorized claims via the AutoCompounder guard
        return address(uint160(uint256(positionId))); // Placeholder
    }

    // ─── VIEW FUNCTIONS ──────────────────────────────────────────

    /// @notice Get current fund state snapshot
    function getFundState() external view returns (XenorizeTypes.InsuranceFundState memory state) {
        state = XenorizeTypes.InsuranceFundState({
            balance0:         fundBalance0,
            balance1:         fundBalance1,
            totalClaimed0:    totalPaidOut0,
            totalClaimed1:    totalPaidOut1,
            pendingClaims:    0, // Phase 2: queue system
            claimsSuspended:  paused(),
            lastUpdatedBlock: block.number
        });
    }

    /// @notice Fund health ratio (BPS of TVL covered)
    function getFundHealthBps() external view returns (uint256) {
        return _getFundHealthBps();
    }

    /// @notice Check if a position is eligible to claim
    function isEligibleToClaim(bytes32 positionId) external view returns (bool) {
        address owner_ = _getPositionOwner(positionId);
        uint256 lastClaim = lastClaimTime[owner_];
        return !paused() && (lastClaim == 0 || block.timestamp >= lastClaim + CLAIM_COOLDOWN);
    }

    // ─── GOVERNANCE ──────────────────────────────────────────────

    /// @notice Update TVL estimate (called by AutoCompounder on deposit/withdraw)
    function updateTVL(uint256 newTVL) external onlyAutoCompounder {
        totalTVL = newTVL;
        emit TVLUpdated(newTVL);

        // Check if fund health recovers after TVL update
        if (paused() && _getFundHealthBps() >= MIN_FUND_RATIO_BPS) {
            _unpause();
            emit ClaimsResumed();
        }
    }

    /// @notice Authorize/deauthorize a depositor
    function setAuthorizedDepositor(
        address depositor,
        bool authorized
    ) external onlyOwner {
        if (depositor == address(0)) revert XenorizeTypes.Xenorize__ZeroAddress();
        authorizedDepositors[depositor] = authorized;
        emit DepositorAuthorized(depositor, authorized);
    }

    /// @notice Emergency pause by owner (multisig)
    function emergencyPause() external onlyOwner {
        _pause();
        emit ClaimsSuspended("Emergency pause by owner");
    }

    /// @notice Resume claims after emergency
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit ClaimsResumed();
    }
}
