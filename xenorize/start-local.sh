#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-local.sh — Launch Anvil mainnet fork + deploy Xenorize contracts
#
# Usage:
#   ./start-local.sh [rpc-url]
#
# If no rpc-url is given, uses $ETH_RPC_URL env var.
# Get a free RPC from: https://app.infura.io  or  https://alchemy.com
#
# After running, click "Anvil Local" in the dashboard to connect.
# ─────────────────────────────────────────────────────────────────────────────
set -e

RPC_URL="${1:-$ETH_RPC_URL}"

if [ -z "$RPC_URL" ]; then
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║  ERROR: No RPC URL provided                              ║"
  echo "  ║                                                          ║"
  echo "  ║  Usage:  ./start-local.sh https://mainnet.infura.io/v3/XXX ║"
  echo "  ║  Or set: export ETH_RPC_URL=https://...                 ║"
  echo "  ║                                                          ║"
  echo "  ║  Get a free key at: https://app.infura.io               ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo ""
  exit 1
fi

# Uniswap V4 PoolManager on Ethereum mainnet
POOL_MANAGER="0x000000000004444c5dc75cB358380D2e3dE08A90"
# Chainlink ETH/USD on mainnet
ETH_USD_FEED="0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"

ANVIL_PORT=8545
ANVIL_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # Anvil account 0

echo ""
echo "  ⚡ Xenorize Local Dev — Mainnet Fork"
echo "  ══════════════════════════════════════"
echo "  RPC        : $RPC_URL"
echo "  PoolManager: $POOL_MANAGER"
echo "  Port       : $ANVIL_PORT"
echo ""

# Kill any existing anvil
pkill -f "anvil" 2>/dev/null || true
sleep 1

echo "  ▶ Starting Anvil mainnet fork..."
anvil \
  --fork-url "$RPC_URL" \
  --port "$ANVIL_PORT" \
  --block-time 2 \
  --chain-id 31337 \
  --silent &

ANVIL_PID=$!
echo "  ✓ Anvil PID: $ANVIL_PID"
sleep 3

echo "  ▶ Deploying Xenorize contracts..."
OUTPUT=$(PRIVATE_KEY="$ANVIL_PK" \
  POOL_MANAGER_ADDRESS="$POOL_MANAGER" \
  ETH_USD_FEED="$ETH_USD_FEED" \
  forge script script/Deploy.s.sol \
    --rpc-url "http://127.0.0.1:$ANVIL_PORT" \
    --broadcast \
    --private-key "$ANVIL_PK" \
    2>&1)

echo "$OUTPUT"

# Extract addresses from output
INSURANCE=$(echo "$OUTPUT" | grep "InsuranceFund  :" | tail -1 | awk '{print $NF}')
ORACLE=$(echo "$OUTPUT"     | grep "Oracle         :" | tail -1 | awk '{print $NF}')
HOOK=$(echo "$OUTPUT"       | grep "DynamicFeeHook :" | tail -1 | awk '{print $NF}')
COMPOUNDER=$(echo "$OUTPUT" | grep "AutoCompounder :" | tail -1 | awk '{print $NF}')

if [ -z "$INSURANCE" ]; then
  echo "  ✗ Deployment failed — see output above"
  kill $ANVIL_PID 2>/dev/null
  exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  DEPLOYMENT COMPLETE — update contracts.js with:        ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║  insuranceFund:  $INSURANCE  ║"
echo "  ║  oracle:         $ORACLE  ║"
echo "  ║  dynamicFeeHook: $HOOK  ║"
echo "  ║  autoCompounder: $COMPOUNDER  ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# Auto-update contracts.js
CONTRACTS_JS="frontend-react/src/lib/contracts.js"
if [ -f "$CONTRACTS_JS" ]; then
  sed -i "s|insuranceFund:.*|insuranceFund:   \"$INSURANCE\",|"  "$CONTRACTS_JS"
  sed -i "s|autoCompounder:.*|autoCompounder:  \"$COMPOUNDER\",|" "$CONTRACTS_JS"
  sed -i "s|dynamicFeeHook:.*|dynamicFeeHook:  \"$HOOK\",|"       "$CONTRACTS_JS"
  sed -i "s|oracle:.*|oracle:          \"$ORACLE\",|"             "$CONTRACTS_JS"
  echo "  ✓ contracts.js updated automatically"
fi

echo "  ✓ Anvil running at http://127.0.0.1:$ANVIL_PORT"
echo "  ✓ Click 'Anvil Local' in the dashboard to connect"
echo "  ✓ Chainlink ETH/USD feed is LIVE (mainnet fork)"
echo ""
echo "  Press Ctrl+C to stop Anvil"
echo ""

# Keep script alive and wait for anvil
wait $ANVIL_PID
