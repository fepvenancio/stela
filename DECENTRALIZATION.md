# Stela Protocol — Decentralization

## Ownership Renouncement

All three Stela protocol contracts have permanently renounced admin ownership via OpenZeppelin's `renounce_ownership()`. This means:
- No entity can pause, upgrade, or modify the protocol
- All parameters are permanently locked at their current values
- The protocol runs autonomously on StarkNet

## Contract Addresses (Sepolia)

| Contract | Address | Voyager |
|----------|---------|---------|
| Stela Protocol | `0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973` | [View](https://sepolia.voyager.online/contract/0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973) |
| StelaGenesis NFT | `0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3` | [View](https://sepolia.voyager.online/contract/0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3) |
| FeeVault | `0x0111beaef1d9b13378b0dbf1be40c556ccf6886591f6b1b29ed790fa13606471` | [View](https://sepolia.voyager.online/contract/0x0111beaef1d9b13378b0dbf1be40c556ccf6886591f6b1b29ed790fa13606471) |

## Permanently Locked Parameters

### Stela Protocol
- `pause() / unpause()` — protocol cannot be paused
- `set_relayer_fee()` — locked at 10 BPS
- `set_treasury()` — locked at current treasury address
- `set_privacy_pool()` — no privacy pool linked (Sepolia; will redeploy for mainnet)
- `set_fee_vault()` — locked at current FeeVault address
- `set_inscription_fee()` — locked at current value
- `set_implementation_hash()` — locker TBA logic locked
- `set_registry()` — SNIP-14 registry locked

### StelaGenesis NFT
- `set_mint_price()` — locked at 5,000 STRK
- `set_mint_enabled()` — locked at current state
- `admin_mint()` — permanently disabled

### FeeVault
- All admin functions permanently disabled

## Permissionless Functions

All user-facing functions require NO special permissions:

| Function | Who Can Call | Description |
|----------|-------------|-------------|
| `settle()` | Anyone (relayer) | Settles matched orders, caller earns 5 BPS |
| `liquidate()` | Anyone | Liquidates expired inscriptions |
| `claim()` | Any Genesis NFT holder | Claims accumulated fees from FeeVault |
| `redeem()` | Any share holder | Redeems ERC1155 shares after repayment |
| `create_inscription()` | Any user | Creates on-chain lending inscription |
| `sign_inscription()` | Any user | Signs/funds an inscription |
| `repay()` | Borrower | Repays a loan |

## Running a Relayer

Anyone can run a relayer to earn 5 BPS on each settlement. See the [stela-relayer](https://github.com/fepvenancio/stela-relayer) repository for a standalone implementation.

## Verification

Verify ownership renouncement:
```bash
sncast call --contract-address 0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973 --function owner
# Returns: 0x0

sncast call --contract-address 0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3 --function owner
# Returns: 0x0

sncast call --contract-address 0x0111beaef1d9b13378b0dbf1be40c556ccf6886591f6b1b29ed790fa13606471 --function owner
# Returns: 0x0
```
