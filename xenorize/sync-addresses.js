#!/usr/bin/env node
/**
 * sync-addresses.js
 * Reads the latest forge broadcast and syncs contract addresses to:
 *   - frontend-react/src/lib/contracts.js
 *   - keeper-bot/.env
 *
 * Usage:
 *   node sync-addresses.js              (chain 31337 / Anvil default)
 *   node sync-addresses.js --chain 1    (mainnet)
 */

const fs   = require("fs");
const path = require("path");

// ── Config ─────────────────────────────────────────────────────────────────

const chain = (() => {
  const idx = process.argv.indexOf("--chain");
  return idx !== -1 ? process.argv[idx + 1] : "31337";
})();

const ROOT = __dirname;

// Prefer AnvilSetup broadcast (has PoolManager + tokens), fall back to Deploy
const BROADCAST_ANVIL  = path.join(ROOT, "broadcast", "AnvilSetup.s.sol", chain, "run-latest.json");
const BROADCAST_DEPLOY = path.join(ROOT, "broadcast", "Deploy.s.sol",    chain, "run-latest.json");
const BROADCAST        = fs.existsSync(BROADCAST_ANVIL) ? BROADCAST_ANVIL : BROADCAST_DEPLOY;

// Resolve relative to this script's location (xenorize/)
const CONTRACTS_JS_REL = path.join(ROOT, "frontend-react", "src", "lib", "contracts.js");
const ENV_FILE_REL     = path.join(ROOT, "keeper-bot", ".env");
// Legacy fallback paths
const CONTRACTS_JS = path.join(ROOT, "..", "xenorize", "frontend-react", "src", "lib", "contracts.js");
const ENV_FILE     = path.join(ROOT, "..", "xenorize", "keeper-bot", ".env");

// ── Read broadcast ──────────────────────────────────────────────────────────

if (!fs.existsSync(BROADCAST)) {
  console.error(`❌  Broadcast file not found: ${BROADCAST}`);
  console.error(`    Run: forge script script/Deploy.s.sol --tc XenorizeDeploy --rpc-url http://127.0.0.1:8545 --broadcast`);
  process.exit(1);
}

const broadcast = JSON.parse(fs.readFileSync(BROADCAST, "utf8"));
const creates   = broadcast.transactions.filter(t => t.transactionType === "CREATE");

// Map contractName → address
const deployed = {};
for (const tx of creates) {
  deployed[tx.contractName] = tx.contractAddress;
}

// Contract name → key mapping
const NAME_MAP = {
  XenorizeAutoCompounder: "autoCompounder",
  XenorizeInsuranceFund:  "insuranceFund",
  XenorizeDynamicFeeHook: "dynamicFeeHook",
  XenorizeChainlinkOracle: "oracle",
  XenorizeAutoRangeHook:  "autoRangeHook",
  XenorizeTWAMMHook:      "twammHook",
  XenorizeMultiPositionStrategyHook: "multiPositionHook",
  XenorizeLoyaltyHook:    "loyaltyHook",
  PoolManager:            "poolManager",
  TestERC20:              null,          // handled separately below
};

const ENV_MAP = {
  autoCompounder:    "AUTO_COMPOUNDER_ADDR",
  insuranceFund:     "INSURANCE_FUND_ADDR",
  dynamicFeeHook:    "DYNAMIC_FEE_HOOK_ADDR",
  oracle:            "ORACLE_ADDR",
  autoRangeHook:     "AUTO_RANGE_HOOK_ADDR",
  twammHook:         "TWAMM_HOOK_ADDR",
  multiPositionHook: "MULTI_POSITION_HOOK_ADDR",
  loyaltyHook:       "LOYALTY_HOOK_ADDR",
  poolManager:       "POOL_MANAGER_ADDR",
  token0:            "TOKEN0_ADDRESS",
  token1:            "TOKEN1_ADDRESS",
};

// Build address table
const addresses = {};
for (const [contractName, key] of Object.entries(NAME_MAP)) {
  if (key && deployed[contractName]) {
    addresses[key] = deployed[contractName];
  }
}

// TestERC20: first deploy = token0, second = token1
const testTokens = creates.filter(t => t.contractName === "TestERC20");
if (testTokens.length >= 1) addresses["token0"] = testTokens[0].contractAddress;
if (testTokens.length >= 2) addresses["token1"] = testTokens[1].contractAddress;

if (Object.keys(addresses).length === 0) {
  console.error("❌  No matching contracts found in broadcast. Check NAME_MAP in sync-addresses.js.");
  process.exit(1);
}

console.log("\n📦  Contracts found in broadcast:");
for (const [key, addr] of Object.entries(addresses)) {
  console.log(`    ${key.padEnd(20)} ${addr}`);
}

// ── Update contracts.js ────────────────────────────────────────────────────

const jsTarget = fs.existsSync(CONTRACTS_JS_REL) ? CONTRACTS_JS_REL : CONTRACTS_JS;

if (fs.existsSync(jsTarget)) {
  let src = fs.readFileSync(jsTarget, "utf8");

  // Replace the entire ADDRESSES block
  const block = Object.entries(addresses)
    .map(([k, v]) => `  ${k}:${" ".repeat(Math.max(1, 17 - k.length))}"${v}",`)
    .join("\n");

  src = src.replace(
    /export const ADDRESSES\s*=\s*\{[^}]*\};/s,
    `export const ADDRESSES = {\n${block}\n};`
  );

  fs.writeFileSync(jsTarget, src, "utf8");
  console.log(`\n✅  Updated: ${path.relative(ROOT, jsTarget)}`);
} else {
  console.warn(`⚠️   contracts.js not found at expected path — skipped`);
}

// ── Update keeper-bot/.env ─────────────────────────────────────────────────

const envTarget = fs.existsSync(ENV_FILE_REL) ? ENV_FILE_REL : ENV_FILE;

if (fs.existsSync(envTarget)) {
  let env = fs.readFileSync(envTarget, "utf8");

  for (const [key, addr] of Object.entries(addresses)) {
    const envKey = ENV_MAP[key];
    if (!envKey) continue;

    const re = new RegExp(`^(${envKey}=).*$`, "m");
    if (re.test(env)) {
      env = env.replace(re, `$1${addr}`);
    } else {
      // Append if key not present
      env += `\n${envKey}=${addr}`;
    }
  }

  fs.writeFileSync(envTarget, env, "utf8");
  console.log(`✅  Updated: ${path.relative(ROOT, envTarget)}`);
} else {
  console.warn(`⚠️   keeper-bot/.env not found — skipped`);
}

console.log("\n🎉  Done. Refresh the frontend to pick up new addresses.\n");
