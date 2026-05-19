// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20}   from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20}  from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import {InsuranceClaim, InsuranceFundState} from "../types/XenorizeTypes.sol";
import {IInsuranceFund} from "../interfaces/IXenorize.sol";
import {
    Xenorize__ZeroAddress,
    Xenorize__ZeroAmount,
    Xenorize__Unauthorized,
    Xenorize__ClaimsSuspended
} from "../types/XenorizeTypes.sol";

/**
 * @title XenorizeInsuranceFund
 * @notice ERC-4626 vault that accumulates protocol fee income and compensates LPs for Impermanent Loss.
 *
 * Income model (increases share NAV — no new shares minted):
 *   depositFee() ← called by ILShieldHook / DynamicFeeHook with protocol fees & MEV capture
 *
 * Staking model (standard ERC-4626):
 *   deposit(assets, receiver) ← anyone can stake the primary asset and earn rising NAV
 *
 * Payout model (reduces totalAssets, lowers NAV slightly per claim):
 *   submitClaim() ← called by ILShieldHook when LP exits a position with IL
 *   Pays: min(50% of IL, loyalty-scaled cap, $10k lifetime cap, fund health cap)
 */
contract XenorizeInsuranceFund is ERC4626, IInsuranceFund, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant MAX_CLAIM_BPS       = 5_000;   // 50% of IL
    uint256 public constant MIN_FUND_HEALTH_BPS = 500;     // pause claims below 5% fund/TVL
    uint256 public constant MAX_SINGLE_CLAIM    = 10_000e18; // $10k lifetime per position
    uint256 public constant CLAIM_COOLDOWN      = 7 days;
    uint256 public constant BPS                 = 10_000;

    // ─── Storage ──────────────────────────────────────────────────
    address public immutable owner;

    uint256 public totalTVL;        // managed pool TVL — used for fund health check
    uint256 public totalPaidOut;    // cumulative IL compensation paid
    uint256 public totalFeeIncome;  // cumulative protocol fee income received

    mapping(address => uint256) public lastClaimTime;
    mapping(bytes32 => uint256) public positionTotalClaimed;
    mapping(address => bool)    public authorizedDepositors;

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }
    modifier onlyAuthorized() {
        if (!authorizedDepositors[msg.sender] && msg.sender != owner)
            revert Xenorize__Unauthorized(msg.sender, address(0));
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────
    /**
     * @param _asset   Primary ERC-20 token (e.g. USDC or WETH)
     * @param _owner   Protocol multisig / deployer
     * @param _name    Share token name (e.g. "Xenorize Insurance Share")
     * @param _symbol  Share token symbol (e.g. "xINS")
     */
    constructor(
        address _asset,
        address _owner,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) {
        if (_asset == address(0) || _owner == address(0)) revert Xenorize__ZeroAddress();
        owner = _owner;
        authorizedDepositors[_owner] = true;
    }

    // ─── Protocol fee income ───────────────────────────────────────

    /**
     * @notice Hooks call this to deposit protocol fee income.
     * @dev Does NOT mint shares — increases totalAssets so all existing shareholders earn yield.
     */
    function depositFee(uint256 amount) external nonReentrant onlyAuthorized {
        if (amount == 0) revert Xenorize__ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        totalFeeIncome += amount;
        emit FeeDeposited(msg.sender, amount);
    }

    // ─── IL Claim ─────────────────────────────────────────────────

    /**
     * @notice Called by ILShieldHook when LP removes liquidity with IL.
     * @dev Pays compensation from vault assets in the primary token.
     *      Compensation = min(50% × IL × loyaltyScore, lifetime cap, fund health cap).
     */
    function submitClaim(InsuranceClaim calldata claim)
        external
        nonReentrant
        whenNotPaused
        onlyAuthorized
        returns (uint256 compensated0, uint256 compensated1)
    {
        address recipient = claim.recipient;
        if (recipient == address(0)) return (0, 0);

        if (block.timestamp < lastClaimTime[recipient] + CLAIM_COOLDOWN) return (0, 0);

        _checkFundHealth();

        uint256 maxComp = _calcMaxCompensation(claim.positionId, claim.ilAmountUSD, claim.loyaltyScore);
        if (maxComp == 0) return (0, 0);

        uint256 available = IERC20(asset()).balanceOf(address(this));
        compensated0 = maxComp > available ? available : maxComp;
        compensated1 = 0;

        if (compensated0 == 0) return (0, 0);

        totalPaidOut                          += compensated0;
        lastClaimTime[recipient]               = block.timestamp;
        positionTotalClaimed[claim.positionId] += compensated0;

        IERC20(asset()).safeTransfer(recipient, compensated0);

        emit ClaimPaid(claim.positionId, recipient, compensated0, 0);
    }

    // ─── IInsuranceFund ───────────────────────────────────────────

    function updateTVL(uint256 newTVL) external onlyAuthorized {
        totalTVL = newTVL;
        if (paused() && _getFundHealthBps() >= MIN_FUND_HEALTH_BPS) {
            _unpause();
            emit ClaimsResumed();
        }
    }

    function getFundState() external view returns (InsuranceFundState memory) {
        return InsuranceFundState({
            balance0:        IERC20(asset()).balanceOf(address(this)),
            balance1:        0,
            totalClaimed0:   totalPaidOut,
            totalClaimed1:   0,
            pendingClaims:   0,
            claimsSuspended: paused(),
            lastUpdatedBlock: block.number
        });
    }

    function getMaxClaim(
        bytes32 positionId,
        uint256 ilAmountUSD,
        uint256 /* ilAmount1 */,
        uint256 loyaltyScore
    ) public view returns (uint256 maxToken0, uint256 maxToken1) {
        maxToken0 = _calcMaxCompensation(positionId, ilAmountUSD, loyaltyScore);
        maxToken1 = 0;
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setAuthorizedDepositor(address depositor, bool authorized) external onlyOwner {
        if (depositor == address(0)) revert Xenorize__ZeroAddress();
        authorizedDepositors[depositor] = authorized;
    }

    function emergencyPause()   external onlyOwner { _pause();   emit ClaimsSuspended("Emergency"); }
    function emergencyUnpause() external onlyOwner { _unpause(); emit ClaimsResumed(); }
    function getFundHealthBps() external view returns (uint256) { return _getFundHealthBps(); }

    // ─── ERC-4626 / IInsuranceFund overrides ─────────────────────
    // Both ERC4626 (via IERC4626) and IInsuranceFund declare asset().
    // Explicitly route to ERC4626's implementation.
    function asset()
        public
        view
        override(ERC4626, IInsuranceFund)
        returns (address)
    {
        return super.asset();
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _calcMaxCompensation(
        bytes32 positionId,
        uint256 ilAmount,
        uint256 loyaltyScore
    ) internal view returns (uint256) {
        if (ilAmount == 0) return 0;

        // Max = 50% of IL, scaled by loyalty score (0–10_000 BPS)
        uint256 cap     = (ilAmount * MAX_CLAIM_BPS) / BPS;
        uint256 loyalty = (cap * loyaltyScore) / BPS;

        // Lifetime per-position cap
        uint256 alreadyClaimed = positionTotalClaimed[positionId];
        uint256 remaining      = MAX_SINGLE_CLAIM > alreadyClaimed
            ? MAX_SINGLE_CLAIM - alreadyClaimed : 0;
        uint256 eligible       = loyalty < remaining ? loyalty : remaining;

        // Reduce proportionally if fund health is low
        uint256 health = _getFundHealthBps();
        if (health < 1_000) eligible = (eligible * health) / BPS;

        return eligible;
    }

    function _getFundHealthBps() internal view returns (uint256) {
        if (totalTVL == 0) return BPS;
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        return (balance * BPS) / totalTVL;
    }

    function _checkFundHealth() internal {
        if (_getFundHealthBps() < MIN_FUND_HEALTH_BPS) {
            _pause();
            emit ClaimsSuspended("Fund below minimum ratio");
        }
    }
}
