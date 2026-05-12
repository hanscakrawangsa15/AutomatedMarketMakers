// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Deployment Script
//
// Deploy sequence (order matters!):
//   1. InsuranceFund
//   2. DynamicFeeHook (requires mined CREATE2 address)
//   3. AutoCompounder (references Fund + Hook)
//   4. Configure authorizations
//   5. Seed insurance fund
//   6. Initialize pool in Uniswap v4 PoolManager
//
// Usage:
//   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC \
//     --broadcast --verify --slow
// ─────────────────────────────────────────────────────────────────

import {Script, console2} from "forge-std/Script.sol";
import {XenorizeInsuranceFund} from "../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder} from "../src/core/AutoCompounder.sol";
import {XenorizeDynamicFeeHook} from "../src/hooks/DynamicFeeHook.sol";

contract XenorizeDeploy is Script {

    // ─── Configuration ───────────────────────────────────────────
    // These are set via environment variables

    address poolManager;   // Uniswap v4 PoolManager
    address owner;         // Protocol multisig
    address feeRecipient;  // Fee recipient
    address oracle;        // AI Oracle (deployed separately)
    address token0;        // e.g., USDC
    address token1;        // e.g., WETH
    address ethUsdFeed;    // Chainlink ETH/USD

    // Deployed contract addresses (filled during deployment)
    XenorizeInsuranceFund  insuranceFund;
    XenorizeAutoCompounder autoCompounder;
    XenorizeDynamicFeeHook feeHook;

    function setUp() public {
        poolManager  = vm.envAddress("POOL_MANAGER_ADDRESS");
        owner        = vm.envAddress("MULTISIG_ADDRESS");
        feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        oracle       = vm.envOr("ORACLE_ADDRESS", address(0)); // Optional at first
        ethUsdFeed   = vm.envOr("ETH_USD_FEED", address(0));
        token0       = vm.envAddress("TOKEN0_ADDRESS"); // USDC
        token1       = vm.envAddress("TOKEN1_ADDRESS"); // WETH
    }

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("=== XENORIZE AMM DEPLOYMENT ===");
        console2.log("Network:   ", block.chainid);
        console2.log("Deployer:  ", deployer);
        console2.log("Owner:     ", owner);
        console2.log("Token0:    ", token0);
        console2.log("Token1:    ", token1);
        console2.log("");

        vm.startBroadcast(deployerKey);

        // ── STEP 1: Deploy Insurance Fund ────────────────────────
        console2.log("Step 1: Deploying InsuranceFund...");
        insuranceFund = new XenorizeInsuranceFund(
            owner,
            address(0), // AutoCompounder address: set after deploy
            token0,
            token1
        );
        console2.log("  InsuranceFund:  ", address(insuranceFund));

        // ── STEP 2: Deploy Dynamic Fee Hook ──────────────────────
        // NOTE: In production, you MUST use CREATE2 mining to get
        //       an address with the correct permission bits set.
        //       See script/MineHookAddress.s.sol for the mining script.
        //       For testnet, we skip this requirement for simplicity.
        console2.log("Step 2: Deploying DynamicFeeHook...");
        feeHook = new XenorizeDynamicFeeHook(
            poolManager,
            owner,
            feeRecipient,
            oracle,
            ethUsdFeed
        );
        console2.log("  DynamicFeeHook: ", address(feeHook));
        console2.log("  WARN: Verify hook address bit pattern for mainnet!");

        // ── STEP 3: Deploy AutoCompounder ────────────────────────
        console2.log("Step 3: Deploying AutoCompounder...");
        autoCompounder = new XenorizeAutoCompounder(
            owner,
            poolManager,
            address(insuranceFund),
            token0,
            token1,
            oracle
        );
        console2.log("  AutoCompounder: ", address(autoCompounder));

        // ── STEP 4: Wire up authorizations ───────────────────────
        console2.log("Step 4: Configuring authorizations...");

        // Let AutoCompounder deposit into InsuranceFund
        // NOTE: This must be called by owner — change ownership first
        // In production: transferOwnership to multisig before this
        // insuranceFund.setAuthorizedDepositor(address(autoCompounder), true);
        console2.log("  TODO: Call insuranceFund.setAuthorizedDepositor(autoCompounder)");
        console2.log("        via multisig after transferring ownership");

        vm.stopBroadcast();

        // ── STEP 5: Print deployment summary ─────────────────────
        console2.log("");
        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("InsuranceFund:  ", address(insuranceFund));
        console2.log("DynamicFeeHook: ", address(feeHook));
        console2.log("AutoCompounder: ", address(autoCompounder));
        console2.log("");
        console2.log("=== POST-DEPLOY CHECKLIST ===");
        console2.log("[ ] Transfer ownership to multisig");
        console2.log("[ ] setAuthorizedDepositor(autoCompounder)");
        console2.log("[ ] Seed insurance fund ($5K minimum)");
        console2.log("[ ] Initialize pool in PoolManager with feeHook");
        console2.log("[ ] Start keeper bot");
        console2.log("[ ] Set TVL cap to $50K");
        console2.log("[ ] Verify contracts on Etherscan");
        console2.log("[ ] Open bug bounty");
    }
}

/// @notice Script to find valid CREATE2 salt for hook address
/// @dev Run this BEFORE deploying DynamicFeeHook to mainnet
/// @dev Required bits: bit7 + bit6 must be set (beforeSwap + afterSwap)
contract MineHookAddress is Script {

    // Target: address must have last 2 bytes with bits 7&6 set
    // bit pattern: 0b11000000 = 0xC0
    // The 13th and 14th bytes (0-indexed) of address must have this pattern
    uint256 constant TARGET_BITS = (1 << 7) | (1 << 6); // 0xC0

    function run() public view {
        address deployer    = vm.envAddress("DEPLOYER_ADDRESS");
        bytes32 bytecodeHash = vm.envBytes32("HOOK_BYTECODE_HASH");

        console2.log("Mining CREATE2 address for DynamicFeeHook...");
        console2.log("Deployer:     ", deployer);
        console2.log("Target bits:  0xC0 (beforeSwap + afterSwap)");
        console2.log("This may take seconds to minutes...");

        uint256 foundSalt;
        address foundAddress;
        bool    found;

        // Mine up to 10 million iterations
        for (uint256 salt = 0; salt < 10_000_000; salt++) {
            address predicted = _computeCreate2Address(
                deployer,
                bytes32(salt),
                bytecodeHash
            );

            // Check if last byte has required bits
            uint8 lastByte = uint8(uint160(predicted));
            if ((lastByte & uint8(TARGET_BITS)) == uint8(TARGET_BITS)) {
                foundSalt    = salt;
                foundAddress = predicted;
                found        = true;
                break;
            }
        }

        if (found) {
            console2.log("");
            console2.log("=== FOUND VALID SALT ===");
            console2.log("Salt:    ", foundSalt);
            console2.log("Address: ", foundAddress);
            console2.log("Set HOOK_SALT=", foundSalt, "in .env before deploying");
        } else {
            console2.log("No valid salt found in 10M iterations.");
            console2.log("Try a different bytecodeHash or increase iterations.");
        }
    }

    function _computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 bytecodeHash
    ) internal pure returns (address predicted) {
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            bytecodeHash
        )))));
    }
}
