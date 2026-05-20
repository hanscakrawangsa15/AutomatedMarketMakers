#!/bin/bash
# check-deployment.sh — verifikasi semua contract terdeploy setelah AnvilSetup
# Usage: bash check-deployment.sh

RPC="http://127.0.0.1:8545"
BROADCAST="broadcast/AnvilSetup.s.sol/31337/run-latest.json"

if [ ! -f "$BROADCAST" ]; then
  echo "❌  Broadcast file tidak ditemukan. Jalankan AnvilSetup.s.sol dulu."
  exit 1
fi

echo ""
echo "📋  Verifikasi deployment..."
echo ""

ALL_OK=true

python3 - <<'EOF'
import json, subprocess, sys

RPC = "http://127.0.0.1:8545"
BROADCAST = "broadcast/AnvilSetup.s.sol/31337/run-latest.json"

d = json.load(open(BROADCAST))
creates = [t for t in d["transactions"] if t["transactionType"] == "CREATE"]

for t in creates:
    addr = t["contractAddress"]
    name = t.get("contractName", "?")
    r = subprocess.run(
        ["cast", "code", addr, "--rpc-url", RPC],
        capture_output=True, text=True
    )
    code = r.stdout.strip()
    ok = len(code) > 4
    icon = "✅" if ok else "❌"
    print(f"{icon}  {name:35} {addr}")
    if not ok:
        print(f"   ⚠️  EMPTY — contract not deployed!")

EOF

echo ""
echo "Jika ada ❌, jalankan:"
echo "  1. Ctrl+C Anvil → restart: anvil --block-time 1"
echo "  2. forge script script/AnvilSetup.s.sol --tc AnvilSetup --rpc-url http://127.0.0.1:8545 --broadcast"
echo "  3. node sync-addresses.js"
echo ""
