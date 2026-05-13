// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "../lib/forge-std/src/Script.sol";
import {XenorizeInsuranceFund} from "../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder} from "../src/core/AutoCompounder.sol";
import {XenorizeDynamicFeeHook} from "../src/hooks/DynamicFeeHook.sol";

contract XenorizeDeploy is Script {

    // ─── Deployed addresses (filled during run) ──────────────────
    XenorizeInsuranceFund  public insuranceFund;
    XenorizeAutoCompounder public autoCompounder;
    XenorizeDynamicFeeHook public feeHook;

    function run() public {
        // ── Read config from env ─────────────────────────────────
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);

        // For testnet: use deployer as owner/recipient if no multisig yet
        address owner        = vm.envOr("MULTISIG_ADDRESS",      deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT_ADDRESS", deployer);
        address poolManager  = vm.envOr("POOL_MANAGER_ADDRESS",  address(0xDEAD));
        address oracle       = vm.envOr("ORACLE_ADDRESS",        address(0));
        address ethUsdFeed   = vm.envOr("ETH_USD_FEED",          address(0));
        address token0       = vm.envOr("TOKEN0_ADDRESS",        address(0));
        address token1       = vm.envOr("TOKEN1_ADDRESS",        address(0));

        console2.log("=================================================");
        console2.log("   XENORIZE AMM -- DEPLOYMENT");
        console2.log("=================================================");
        console2.log("Chain ID  :", block.chainid);
        console2.log("Deployer  :", deployer);
        console2.log("Owner     :", owner);
        console2.log("Token0    :", token0);
        console2.log("Token1    :", token1);
        console2.log("-------------------------------------------------");

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy InsuranceFund ─────────────────────────
        console2.log("Deploying InsuranceFund...");
        insuranceFund = new XenorizeInsuranceFund(
            owner,
            deployer,   // autoCompounder placeholder -- update after step 3
            token0 != address(0) ? token0 : address(new MockToken("USDC","USDC")),
            token1 != address(0) ? token1 : address(new MockToken("WETH","WETH"))
        );
        console2.log("  InsuranceFund :", address(insuranceFund));

        // ── Step 2: Deploy DynamicFeeHook ────────────────────────
        console2.log("Deploying DynamicFeeHook...");
        feeHook = new XenorizeDynamicFeeHook(
            poolManager,
            owner,
            feeRecipient,
            oracle,
            ethUsdFeed
        );
        console2.log("  DynamicFeeHook:", address(feeHook));

        // ── Step 3: Deploy AutoCompounder ────────────────────────
        console2.log("Deploying AutoCompounder...");
        autoCompounder = new XenorizeAutoCompounder(
            owner,
            poolManager,
            address(insuranceFund),
            address(insuranceFund.token0()),
            address(insuranceFund.token1()),
            oracle
        );
        console2.log("  AutoCompounder:", address(autoCompounder));

        // ── Step 4: Authorize AutoCompounder in InsuranceFund ────
        console2.log("Configuring authorizations...");
        insuranceFund.setAuthorizedDepositor(address(autoCompounder), true);
        console2.log("  AutoCompounder authorized in InsuranceFund");

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────
        console2.log("=================================================");
        console2.log("   DEPLOYMENT COMPLETE");
        console2.log("=================================================");
        console2.log("InsuranceFund  :", address(insuranceFund));
        console2.log("DynamicFeeHook :", address(feeHook));
        console2.log("AutoCompounder :", address(autoCompounder));
        console2.log("=================================================");
        console2.log("POST-DEPLOY CHECKLIST:");
        console2.log("[ ] Verify contracts on block explorer");
        console2.log("[ ] Seed insurance fund with initial tokens");
        console2.log("[ ] Set TVL cap via setMaxTVLCap()");
        console2.log("[ ] Start keeper bot");
        console2.log("[ ] Open bug bounty");
        console2.log("=================================================");
    }
}

// ── Minimal mock token for testnet deploy without real tokens ─────
contract MockToken {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name; symbol = _symbol;
    }
    function mint(address to, uint256 amt) external {
        totalSupply += amt; balanceOf[to] += amt;
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt);
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address fr, address to, uint256 amt) external returns (bool) {
        require(allowance[fr][msg.sender] >= amt);
        require(balanceOf[fr] >= amt);
        allowance[fr][msg.sender] -= amt;
        balanceOf[fr] -= amt; balanceOf[to] += amt; return true;
    }
}
