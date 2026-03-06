# Stela Protocol — Decentralization

## Ownership Renouncement

Both Stela protocol contracts have permanently renounced admin ownership via OpenZeppelin's `renounce_ownership()`. This means:
- No entity can pause, upgrade, or modify the protocol
- All parameters are permanently locked at their current values
- The protocol runs autonomously on StarkNet

## Contract Addresses (Sepolia)

| Contract | Address | Voyager |
|----------|---------|---------|
| Stela Protocol | `0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973` | [View](https://sepolia.voyager.online/contract/0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973) |
| StelaGenesis NFT | `0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3` | [View](https://sepolia.voyager.online/contract/0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3) |

## Permanently Locked Parameters

### Stela Protocol
- `pause() / unpause()` — protocol cannot be paused
- `set_relayer_fee()` — locked at 10 BPS
- `set_treasury()` — locked at treasury address
- `set_genesis_contract()` — locked at current Genesis NFT address
- `set_inscription_fee()` — locked at current value
- `set_implementation_hash()` — locker TBA logic locked
- `set_registry()` — SNIP-14 registry locked

### StelaGenesis NFT
- `set_mint_price()` — locked at 1,000 STRK
- `set_mint_enabled()` — locked at current state
- `admin_mint()` — permanently disabled

## Permissionless Functions

All user-facing functions require NO special permissions:

| Function | Who Can Call | Description |
|----------|-------------|-------------|
| `settle()` | Anyone (relayer) | Settles matched orders, caller earns 5 BPS |
| `liquidate()` | Anyone | Liquidates expired inscriptions |
| `redeem()` | Any share holder | Redeems ERC1155 shares after repayment |
| `create_inscription()` | Any user | Creates on-chain lending inscription |
| `sign_inscription()` | Any user | Signs/funds an inscription |
| `repay()` | Borrower | Repays a loan |

## Fee Distribution

Fees are transferred directly to the treasury address. Genesis NFT holders receive fee discounts (15% base + volume tiers + per-NFT bonus, cap 50%) rather than fee revenue.

| Event | Total | Relayer | Treasury |
|-------|-------|---------|----------|
| Settlement | 20 BPS | 5 BPS | 15 BPS |
| Redemption | 10 BPS | 0 BPS | 10 BPS |
| Liquidation | 0 BPS | 0 BPS | 0 BPS |

## Running a Relayer

Anyone can run a relayer to earn 5 BPS on each settlement. See the [stela-relayer](https://github.com/fepvenancio/stela-relayer) repository for a standalone implementation.

## Verification

Verify ownership renouncement:
```bash
sncast call --contract-address 0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973 --function owner
# Returns: 0x0

sncast call --contract-address 0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3 --function owner
# Returns: 0x0
```
