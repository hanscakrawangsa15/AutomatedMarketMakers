// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}  from "forge-std/Script.sol";
import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {XenorizeInsuranceFund}   from "../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder}  from "../src/core/AutoCompounder.sol";
import {XenorizeDynamicFeeHook}  from "../src/hooks/DynamicFeeHook.sol";
import {XenorizeChainlinkOracle} from "../src/oracles/XenorizeChainlinkOracle.sol";

/// @title XenorizeDeploy
/// @notice Deploys all Xenorize contracts to any EVM network.
///
///         DynamicFeeHook note:
///         In production, the hook address must satisfy Uniswap V4 permission
///         bits (BEFORE_SWAP | AFTER_SWAP = 0x00C0). Use HookMiner + CREATE2
///         externally before this script on mainnet.
///         For local dev (Anvil), the hook still works; just call
///         hook.validateHookAddress() to check — it will return false on Anvil
///         because we deploy to a random address, but all hook logic works.
contract XenorizeDeploy is Script {

    XenorizeInsuranceFund   public insuranceFund;
    XenorizeAutoCompounder  public autoCompounder;
    XenorizeDynamicFeeHook  public feeHook;
    XenorizeChainlinkOracle public oracle;

    function run() public {
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address owner        = vm.envOr("MULTISIG_ADDRESS",      deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT_ADDRESS", deployer);
        address poolMgrAddr  = vm.envOr("POOL_MANAGER_ADDRESS",  address(0xDEAD));
        address gasFeed      = vm.envOr("GAS_FEED_ADDRESS",      address(0));
        address ethUsdFeed   = vm.envOr("ETH_USD_FEED",          address(0));
        address token0Addr   = vm.envOr("TOKEN0_ADDRESS",        address(0));
        address token1Addr   = vm.envOr("TOKEN1_ADDRESS",        address(0));

        IPoolManager poolManager = IPoolManager(poolMgrAddr);

        console2.log("=================================================");
        console2.log("   XENORIZE AMM -- DEPLOYMENT");
        console2.log("=================================================");
        console2.log("Chain ID   :", block.chainid);
        console2.log("Deployer   :", deployer);
        console2.log("Owner      :", owner);
        console2.log("PoolManager:", poolMgrAddr);
        console2.log("-------------------------------------------------");

        vm.startBroadcast(deployerKey);

        // ── 1. Mock tokens (if no real tokens provided) ───────────
        address t0 = token0Addr != address(0)
            ? token0Addr : address(new MockToken("USDC", "USDC"));
        address t1 = token1Addr != address(0)
            ? token1Addr : address(new MockToken("WETH", "WETH"));
        console2.log("Token0 :", t0);
        console2.log("Token1 :", t1);

        // ── 2. InsuranceFund ──────────────────────────────────────
        console2.log("Deploying InsuranceFund...");
        insuranceFund = new XenorizeInsuranceFund(owner, deployer, t0, t1);
        console2.log("  InsuranceFund :", address(insuranceFund));

        // ── 3. Chainlink Oracle ───────────────────────────────────
        console2.log("Deploying Oracle...");
        oracle = new XenorizeChainlinkOracle(poolManager, owner, gasFeed);
        console2.log("  Oracle        :", address(oracle));

        // ── 4. DynamicFeeHook ─────────────────────────────────────
        console2.log("Deploying DynamicFeeHook...");
        feeHook = new XenorizeDynamicFeeHook(
            poolManager, owner, feeRecipient,
            address(insuranceFund), address(oracle), ethUsdFeed
        );
        console2.log("  DynamicFeeHook:", address(feeHook));
        console2.log("  Hook addr valid:", feeHook.validateHookAddress());

        // ── 5. AutoCompounder ─────────────────────────────────────
        console2.log("Deploying AutoCompounder...");
        autoCompounder = new XenorizeAutoCompounder(
            owner, poolManager, address(insuranceFund), t0, t1, address(oracle)
        );
        console2.log("  AutoCompounder:", address(autoCompounder));

        // ── 6. Wire authorizations ────────────────────────────────
        insuranceFund.setAuthorizedDepositor(address(autoCompounder), true);
        insuranceFund.setAuthorizedDepositor(address(feeHook),        true);
        console2.log("Authorizations set.");

        vm.stopBroadcast();

        console2.log("=================================================");
        console2.log("   DEPLOYMENT COMPLETE");
        console2.log("=================================================");
        console2.log("InsuranceFund  :", address(insuranceFund));
        console2.log("Oracle         :", address(oracle));
        console2.log("DynamicFeeHook :", address(feeHook));
        console2.log("AutoCompounder :", address(autoCompounder));
        console2.log("=================================================");
        console2.log("Update frontend-react/src/lib/contracts.js with the above addresses.");
        console2.log("=================================================");
    }
}

// ── Minimal mock ERC-20 ───────────────────────────────────────────
contract MockToken {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) { name = _name; symbol = _symbol; }
    function mint(address to, uint256 amt) external {
        totalSupply += amt; balanceOf[to] += amt; emit Transfer(address(0), to, amt);
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt); balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt); return true;
    }
    function transferFrom(address fr, address to, uint256 amt) external returns (bool) {
        require(allowance[fr][msg.sender] >= amt && balanceOf[fr] >= amt);
        allowance[fr][msg.sender] -= amt; balanceOf[fr] -= amt; balanceOf[to] += amt;
        emit Transfer(fr, to, amt); return true;
    }
}
