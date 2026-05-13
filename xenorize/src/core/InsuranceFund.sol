// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {XenorizeMath} from "../libraries/XenorizeMath.sol";
import {InsuranceClaim, InsuranceFundState, Xenorize__ZeroAddress, Xenorize__Unauthorized, Xenorize__ZeroAmount, Xenorize__ClaimsSuspended} from "../types/XenorizeTypes.sol";
import {IInsuranceFund} from "../interfaces/IXenorize.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

contract XenorizeInsuranceFund is IInsuranceFund, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable autoCompounder;
    IERC20  public immutable token0;
    IERC20  public immutable token1;

    uint256 public constant MAX_CLAIM_BPS        = 5_000;
    uint256 public constant MIN_FUND_RATIO_BPS   = 500;
    uint256 public constant MAX_SINGLE_CLAIM_USD = 10_000e18;
    uint256 public constant CLAIM_COOLDOWN       = 7 days;
    uint256 public constant BPS                  = 10_000;

    uint256 public fundBalance0;
    uint256 public fundBalance1;
    uint256 public totalPaidOut0;
    uint256 public totalPaidOut1;
    uint256 public totalDeposited0;
    uint256 public totalDeposited1;
    uint256 public totalTVL;

    mapping(address  => uint256) public lastClaimTime;
    mapping(bytes32  => uint256) public positionClaimed0;
    mapping(address  => bool)    public authorizedDepositors;

    event DepositorAuthorized(address indexed depositor, bool authorized);
    event TVLUpdated(uint256 newTVL);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }
    modifier onlyAutoCompounder() {
        if (msg.sender != autoCompounder) revert Xenorize__Unauthorized(msg.sender, autoCompounder);
        _;
    }
    modifier onlyAuthorized() {
        if (!authorizedDepositors[msg.sender] && msg.sender != owner)
            revert Xenorize__Unauthorized(msg.sender, address(0));
        _;
    }

    constructor(address _owner, address _autoCompounder, address _token0, address _token1) {
        if (_owner == address(0) || _autoCompounder == address(0) ||
            _token0 == address(0) || _token1 == address(0)) revert Xenorize__ZeroAddress();
        owner          = _owner;
        autoCompounder = _autoCompounder;
        token0         = IERC20(_token0);
        token1         = IERC20(_token1);
        authorizedDepositors[_autoCompounder] = true;
    }

    function submitClaim(InsuranceClaim calldata claim)
        external nonReentrant whenNotPaused onlyAutoCompounder
        returns (uint256 compensated0, uint256 compensated1)
    {
        address recipient = address(uint160(uint256(claim.positionId)));
        uint256 last      = lastClaimTime[recipient];
        if (last > 0 && block.timestamp < last + CLAIM_COOLDOWN) return (0, 0);

        _checkFundHealth();

        (uint256 max0, uint256 max1) = getMaxClaim(
            claim.positionId, claim.ilAmount0, claim.ilAmount1, claim.loyaltyScore
        );
        if (max0 == 0 && max1 == 0) return (0, 0);

        compensated0 = max0 > fundBalance0 ? fundBalance0 : max0;
        compensated1 = max1 > fundBalance1 ? fundBalance1 : max1;

        fundBalance0 -= compensated0;
        fundBalance1 -= compensated1;
        totalPaidOut0 += compensated0;
        totalPaidOut1 += compensated1;
        lastClaimTime[recipient] = block.timestamp;
        positionClaimed0[claim.positionId] += compensated0;

        if (compensated0 > 0) token0.safeTransfer(recipient, compensated0);
        if (compensated1 > 0) token1.safeTransfer(recipient, compensated1);

        emit ClaimPaid(claim.positionId, recipient, compensated0, compensated1);
    }

    function deposit(uint256 amount0, uint256 amount1) external nonReentrant onlyAuthorized {
        if (amount0 == 0 && amount1 == 0) revert Xenorize__ZeroAmount();
        fundBalance0    += amount0;
        fundBalance1    += amount1;
        totalDeposited0 += amount0;
        totalDeposited1 += amount1;
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        emit FundDeposited(msg.sender, amount0, amount1);
    }

    function getMaxClaim(bytes32 positionId, uint256 ilAmount0, uint256 ilAmount1, uint256 loyaltyScore)
        public view returns (uint256 maxToken0, uint256 maxToken1)
    {
        if (ilAmount0 == 0 && ilAmount1 == 0) return (0, 0);
        uint256 cap0      = (ilAmount0 * MAX_CLAIM_BPS) / BPS;
        uint256 cap1      = (ilAmount1 * MAX_CLAIM_BPS) / BPS;
        uint256 loyal0    = (cap0 * loyaltyScore) / BPS;
        uint256 loyal1    = (cap1 * loyaltyScore) / BPS;
        uint256 remaining = MAX_SINGLE_CLAIM_USD > positionClaimed0[positionId]
            ? MAX_SINGLE_CLAIM_USD - positionClaimed0[positionId] : 0;
        maxToken0 = loyal0 > remaining ? remaining : loyal0;
        maxToken1 = loyal1;
        uint256 health = _getFundHealthBps();
        if (health < 1_000) {
            maxToken0 = (maxToken0 * health) / BPS;
            maxToken1 = (maxToken1 * health) / BPS;
        }
    }

    function getFundState() external view returns (InsuranceFundState memory) {
        return InsuranceFundState({
            balance0: fundBalance0, balance1: fundBalance1,
            totalClaimed0: totalPaidOut0, totalClaimed1: totalPaidOut1,
            pendingClaims: 0, claimsSuspended: paused(), lastUpdatedBlock: block.number
        });
    }

    function updateTVL(uint256 newTVL) external onlyAutoCompounder {
        totalTVL = newTVL;
        emit TVLUpdated(newTVL);
        if (paused() && _getFundHealthBps() >= MIN_FUND_RATIO_BPS) {
            _unpause();
            emit ClaimsResumed();
        }
    }

    function setAuthorizedDepositor(address depositor, bool authorized) external onlyOwner {
        if (depositor == address(0)) revert Xenorize__ZeroAddress();
        authorizedDepositors[depositor] = authorized;
        emit DepositorAuthorized(depositor, authorized);
    }

    function emergencyPause() external onlyOwner { _pause(); emit ClaimsSuspended("Emergency"); }
    function emergencyUnpause() external onlyOwner { _unpause(); emit ClaimsResumed(); }
    function getFundHealthBps() external view returns (uint256) { return _getFundHealthBps(); }

    function _getFundHealthBps() internal view returns (uint256) {
        if (totalTVL == 0) return BPS;
        return (fundBalance0 * BPS) / totalTVL;
    }

    function _checkFundHealth() internal {
        if (_getFundHealthBps() < MIN_FUND_RATIO_BPS) {
            _pause();
            emit ClaimsSuspended("Fund below minimum");
        }
    }
}
