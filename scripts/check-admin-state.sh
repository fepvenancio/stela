#!/usr/bin/env bash
# Pre-renouncement state checker for Stela protocol contracts
# Run this BEFORE calling renounce_ownership() to verify current admin values

set -euo pipefail

STELA="0x042e955a1905261e7afdba17518506c8f275759e1195bc19e2eca908658bf8e9"
GENESIS="0x02405de15c17aaf863bcf23c22706d73d142c8a81df29de9ef129666655847ca"
FEE_VAULT="0x065f7103f01474dcc860d200e9e8eb7c467dbe3f6dcf0af5b84cfa143fb264f6"

echo "=== Stela Protocol ($STELA) ==="
echo "--- Owner ---"
sncast call --contract-address "$STELA" --function owner
echo "--- Fee Vault ---"
sncast call --contract-address "$STELA" --function get_fee_vault
echo "--- Treasury ---"
sncast call --contract-address "$STELA" --function get_treasury
echo "--- Relayer Fee ---"
sncast call --contract-address "$STELA" --function get_relayer_fee
echo "--- Inscription Fee ---"
sncast call --contract-address "$STELA" --function get_inscription_fee
echo "--- Is Paused ---"
sncast call --contract-address "$STELA" --function is_paused
echo ""

echo "=== StelaGenesis NFT ($GENESIS) ==="
echo "--- Owner ---"
sncast call --contract-address "$GENESIS" --function owner
echo ""

echo "=== FeeVault ($FEE_VAULT) ==="
echo "--- Owner ---"
sncast call --contract-address "$FEE_VAULT" --function owner
echo ""

echo "=== Pre-renouncement check complete ==="
echo "Review the values above. If everything looks correct, proceed with renounce_ownership()."
