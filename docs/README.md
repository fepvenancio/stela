# Stela Protocol -- Cairo Contracts Documentation

Stela is a peer-to-peer lending, borrowing, and OTC swap protocol on StarkNet. The name comes from ancient Egyptian stone slabs used to publicly record inscriptions and decrees.

The protocol allows any user to create an **inscription** -- a public offer to borrow or lend -- specifying debt assets, interest assets, collateral assets, a duration, and a deadline. Counterparties sign (fill) these inscriptions on-chain. Collateral is locked in a token-bound account (TBA) during the loan period. Lenders receive ERC-1155 shares representing their position, which they can redeem for underlying assets after repayment or liquidation. The protocol also supports instant OTC swaps (duration = 0) and gasless off-chain order settlement via SNIP-12 signatures.

## Documentation Index

| Document | Description |
|---|---|
| [architecture.md](architecture.md) | System architecture: contract overview (StelaProtocol, LockerAccount), inscription lifecycle (create, sign, repay, liquidate, redeem, cancel), collateral locking via TBA, ERC-1155 share system, OTC swap flow, multi-lender partial fills, off-chain settlement, and ASCII flow diagrams |
| [security.md](security.md) | Security model: locker allowlist lockdown, pausable protocol, reentrancy guards, access control (Ownable, borrower-only repay, creator-only cancel), asset validation rules, treasury fee system, per-inscription balance tracking, timing checks, double-action prevention, off-chain signature security, and full error code reference |
| [deployment.md](deployment.md) | Build instructions (scarb build), test instructions (snforge test), deployment steps for Sepolia/Mainnet (declare LockerAccount, deploy StelaProtocol), post-deployment configuration (set_treasury, set_implementation_hash, set_locker_allowed_selector, set_inscription_fee, set_relayer_fee) |

## Source Code Layout

```
src/
  lib.cairo                      -- Module root
  stela.cairo                    -- StelaProtocol: core contract (ERC-1155, Ownable, Pausable, ReentrancyGuard)
  locker_account.cairo           -- LockerAccount: SNIP-14 token-bound account for collateral
  snip12.cairo                   -- SNIP-12 typed data for off-chain signing (InscriptionOrder, LendOffer)
  errors.cairo                   -- All error constants
  interfaces/
    istela.cairo                 -- IStelaProtocol trait
    ilocker.cairo                -- ILockerAccount trait
    iregistry.cairo              -- IRegistry trait (SNIP-14 TBA registry)
    ierc721_mintable.cairo       -- IERC721Mintable trait (inscription NFT minting)
  types/
    asset.cairo                  -- Asset struct and AssetType enum (ERC20, ERC721, ERC1155, ERC4626)
    inscription.cairo            -- InscriptionParams and StoredInscription structs
  utils/
    share_math.cairo             -- ERC-4626 style share conversion with virtual offset
  mocks/
    mock_erc20.cairo             -- Test mock
    mock_erc721.cairo            -- Test mock
    mock_registry.cairo          -- Test mock
tests/
  test_create_inscription.cairo
  test_sign_inscription.cairo
  test_repay.cairo
  test_liquidate.cairo
  test_redeem.cairo
  test_otc_swap.cairo
  test_multi_lender.cairo
  test_security.cairo
  test_e2e.cairo
  test_utils.cairo
  test_hash_compat.cairo
```

## Toolchain

- **Cairo**: Edition 2024_07
- **StarkNet**: 2.13.1
- **Build system**: Scarb
- **Test framework**: snforge (starknet-foundry) 0.56.0
- **OpenZeppelin**: v3.0.0 (token, access, security, introspection, account), v2.1.0 (interfaces, utils)

## Quick Start

```bash
# Build
scarb build

# Test
snforge test

# Format
scarb fmt
```
