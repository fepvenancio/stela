#!/usr/bin/env bash
# Pre-renouncement state checker for Stela protocol contracts
# Run this BEFORE calling renounce_ownership() to verify current admin values

set -euo pipefail

STELA="0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973"
GENESIS="0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3"
FEE_VAULT="0x0111beaef1d9b13378b0dbf1be40c556ccf6886591f6b1b29ed790fa13606471"

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
