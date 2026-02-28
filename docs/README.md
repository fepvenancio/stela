# Stela Protocol -- Cairo Contracts Documentation

Stela is a peer-to-peer lending, borrowing, and OTC swap protocol on StarkNet. The name comes from ancient Egyptian stone slabs used to publicly record inscriptions and decrees.

The protocol allows any user to create an **inscription** -- a public offer to borrow or lend -- specifying debt assets, interest assets, collateral assets, a duration, and a deadline. Counterparties sign (fill) these inscriptions on-chain. Collateral is locked in a token-bound account (TBA) during the loan period. Lenders receive ERC-1155 shares representing their position, which they can redeem for underlying assets after repayment or liquidation. The protocol also supports instant OTC swaps (duration = 0), gasless off-chain order settlement via SNIP-12 signatures, a signed order matching engine for partial fills, and privacy-preserving lending via a ZK privacy pool.

## Documentation Index

| Document | Description |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture: contracts, components, storage layout, internal functions |
| [SPEC.md](SPEC.md) | Protocol specification: entrypoints, lifecycle, SNIP-12, privacy integration |
| [FLOWS.md](FLOWS.md) | Step-by-step flow diagrams for every protocol operation |
| [TYPES.md](TYPES.md) | All structs and types with field-level documentation |
| [EVENTS.md](EVENTS.md) | All events emitted by StelaProtocol and LockerAccount |
| [SHARE-MATH.md](SHARE-MATH.md) | Share conversion math, per-inscription balance tracking, redemption formulas |
| [SECURITY.md](SECURITY.md) | Security model: reentrancy, pause, access control, nonces, validation, error codes |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Build, test, deploy instructions, contract addresses, checklist |

## Source Code Layout

```
src/
  lib.cairo                      -- Module root (7 submodules)
  stela.cairo                    -- StelaProtocol: core contract (ERC-1155, Ownable, Pausable, ReentrancyGuard, Nonces)
  locker_account.cairo           -- LockerAccount: SNIP-14 token-bound account for collateral
  snip12.cairo                   -- SNIP-12 typed data: InscriptionOrder, LendOffer, hash_assets()
  errors.cairo                   -- All error constants (62 errors across 7 categories)
  interfaces/
    istela.cairo                 -- IStelaProtocol trait (34 functions)
    ilocker.cairo                -- ILockerAccount trait
    iprivacy_pool.cairo          -- IPrivacyPool trait (cross-contract interface)
    iregistry.cairo              -- IRegistry trait (SNIP-14 TBA registry)
    ierc721_mintable.cairo       -- IERC721Mintable trait (inscription NFT minting)
  types/
    asset.cairo                  -- Asset struct and AssetType enum (ERC20, ERC721, ERC1155, ERC4626)
    inscription.cairo            -- InscriptionParams and StoredInscription structs
    signed_order.cairo           -- SignedOrder struct with SNIP-12 StructHash
    private_redeem.cairo         -- PrivateRedeemRequest struct (cross-contract Serde compatible)
  utils/
    share_math.cairo             -- ERC-4626 style share conversion with virtual offset
  mocks/
    mock_erc20.cairo             -- Test ERC20 with mint
    mock_erc721.cairo            -- Test ERC721 with mint (inscription NFTs)
    mock_registry.cairo          -- Test SNIP-14 TBA registry
    mock_account.cairo           -- Test account (always returns VALIDATED)
    mock_privacy_pool.cairo      -- Test privacy pool with deposit/commitment tracking
tests/
  lib.cairo                      -- 13 test modules
  test_create_inscription.cairo  -- Inscription creation and validation
  test_sign_inscription.cairo    -- Signing/filling, share minting
  test_repay.cairo               -- Repayment flow and timing
  test_liquidate.cairo           -- Liquidation flow and timing
  test_redeem.cairo              -- Share redemption (repaid + liquidated)
  test_otc_swap.cairo            -- Duration=0 instant swap flow
  test_multi_lender.cairo        -- Multiple partial fills, share proportionality
  test_security.cairo            -- Access control, pause, double-action prevention
  test_e2e.cairo                 -- Full end-to-end lifecycle
  test_utils.cairo               -- Share math functions
  test_hash_compat.cairo         -- SNIP-12 hash compatibility
  test_private_settle.cairo      -- Private settlement with privacy pool
  test_settle.cairo              -- Off-chain settlement
```

## Toolchain

- **Cairo**: Edition 2024_07
- **StarkNet**: 2.13.1
- **Build system**: Scarb
- **Test framework**: snforge (starknet-foundry) 0.56.0
- **OpenZeppelin**: v3.0.0 (token, access, security, introspection, account), v2.1.0 (interfaces, utils)

## Quick Start

```bash
scarb build       # Build
snforge test      # Test
scarb fmt         # Format
```
