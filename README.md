# Stela — P2P Inscriptions Protocol on StarkNet

> Named after ancient Egyptian stone slabs used to publicly record inscriptions and decrees.

Stela is a trustless peer-to-peer lending and OTC swap protocol. Borrowers create inscriptions specifying collateral, debt, interest, and duration. Any counterparty can fill the inscription — collateral locks into a token-bound account, debt transfers to the borrower, and a repayment timer begins.

## Features

- **P2P Lending** — No liquidity pools, no oracles. Direct borrower-lender inscriptions.
- **OTC Swaps** — Set duration to 0 for instant trustless asset exchanges.
- **Multi-Asset** — Mix ERC-20, ERC-721, ERC-1155, and ERC-4626 in a single inscription.
- **Multi-Lender** — Inscriptions can be partially filled by multiple lenders via ERC-1155 shares.
- **Token-Bound Collateral** — Locked assets sit in a TBA (SNIP-14) owned by the borrower's NFT. The borrower retains proof of control (governance voting, airdrop claiming) but cannot transfer assets out.
- **Transferable Positions** — Both borrower NFTs and lender shares are transferable, enabling secondary markets for debt positions.
- **Off-Chain Settlement** — Gasless order creation via SNIP-12 typed data signatures. A relayer settles matched orders on-chain.
- **Signed Order Matching** — On-chain matching engine for signed orders with partial fills, min-fill thresholds, and batch cancellation.
- **Privacy Pool** — Optional ZK-based private lending. Lenders can commit shares to a Merkle tree and redeem them privately without revealing their identity on-chain.

## How It Works

```
1. Create    — Borrower posts an inscription (collateral, debt, interest, duration)
2. Sign      — Lender fills the inscription (full or partial)
3. Repay     — Borrower repays principal + interest before the deadline
4. Redeem    — Lender burns shares to claim repaid assets
   — OR —
4. Liquidate — If unpaid, anyone triggers liquidation; lender claims collateral
```

### Off-Chain Settlement Flow

```
1. Borrower signs an InscriptionOrder off-chain (SNIP-12 typed data, no gas)
2. Lender signs a LendOffer referencing the order hash
3. Relayer submits both signatures + asset arrays via settle()
4. Contract verifies signatures, creates inscription, and fills it in one transaction
5. Relayer receives a fee (configurable BPS) from the lender's debt transfer
```

### Private Lending Flow

```
1. Lender includes a lender_commitment in the LendOffer (Poseidon hash of owner, inscription_id, shares, salt)
2. On settle(), shares are committed to the privacy pool Merkle tree instead of minting ERC1155
3. Lender later calls private_redeem() with a ZK proof to claim assets anonymously
```

## Build & Test

Requires [Scarb](https://docs.swmansion.com/scarb/download.html) and [StarkNet Foundry](https://foundry-rs.github.io/starknet-foundry/getting-started/installation.html).

```bash
scarb build          # Compile contracts
snforge test         # Run all tests (76 tests)
```

## Project Structure

```
src/
├── stela.cairo              # Core protocol contract (StelaProtocol)
├── locker_account.cairo     # Token-bound account for collateral locking (SNIP-14)
├── snip12.cairo             # SNIP-12 typed data: InscriptionOrder, LendOffer, hash_assets()
├── errors.cairo             # Error constants
├── types/
│   ├── asset.cairo          # Asset struct & AssetType enum (ERC20, ERC721, ERC1155, ERC4626)
│   ├── inscription.cairo    # InscriptionParams & StoredInscription structs
│   ├── signed_order.cairo   # SignedOrder struct for matching engine (SNIP-12)
│   └── private_redeem.cairo # PrivateRedeemRequest struct (cross-contract Serde compat)
├── interfaces/
│   ├── istela.cairo         # IStelaProtocol — full protocol interface
│   ├── ilocker.cairo        # ILockerAccount — locker interface
│   ├── iregistry.cairo      # SNIP-14 registry interface
│   ├── iprivacy_pool.cairo  # IPrivacyPool — privacy pool cross-contract interface
│   └── ierc721_mintable.cairo
├── utils/
│   └── share_math.cairo     # ERC-4626 style share conversion with virtual offset
└── mocks/                   # Mock contracts for testing

tests/
├── test_create_inscription.cairo
├── test_sign_inscription.cairo
├── test_repay.cairo
├── test_liquidate.cairo
├── test_redeem.cairo
├── test_multi_lender.cairo
├── test_otc_swap.cairo
├── test_e2e.cairo           # Full lifecycle integration
├── test_hash_compat.cairo   # SNIP-12 hash compatibility tests
├── test_security.cairo      # Security invariant tests
├── test_utils.cairo         # Test helpers & deployment
└── mocks/                   # Mock contracts (ERC20, ERC721, registry)

docs/
├── architecture.md          # Full protocol architecture
├── security.md              # Security model and threat analysis
├── deployment.md            # Deployment procedures
└── SPEC.md                  # Protocol specification and known limitations
```

## Architecture

### Components (OpenZeppelin)

The contract composes several OpenZeppelin Cairo components:

| Component | Purpose |
|-----------|---------|
| `ERC1155Component` | Lender share tokens (minted on sign, burned on redeem) |
| `OwnableComponent` | Admin access control (fee setting, pausing, etc.) |
| `NoncesComponent` | Replay protection for off-chain SNIP-12 signatures |
| `PausableComponent` | Emergency pause for all state-mutating functions |
| `ReentrancyGuardComponent` | Reentrancy protection on all external calls |
| `SRC5Component` | Interface detection (ERC-165 equivalent) |

### Key Entrypoints

**Inscription Lifecycle:**
- `create_inscription(params)` — Create a new loan request or offer
- `sign_inscription(inscription_id, issued_debt_percentage)` — Fill an inscription (full or partial)
- `cancel_inscription(inscription_id)` — Cancel an unfilled inscription
- `repay(inscription_id)` — Repay principal + interest within the repayment window
- `liquidate(inscription_id)` — Liquidate an expired, unrepaid inscription
- `redeem(inscription_id, shares)` — Burn shares to claim pro-rata assets

**Off-Chain Settlement:**
- `settle(order, debt_assets, interest_assets, collateral_assets, borrower_sig, offer, lender_sig)` — Settle a matched order pair in one transaction

**Signed Order Matching:**
- `fill_signed_order(order, signature, fill_bps)` — Fill a signed order (partial fills supported)
- `cancel_order(order)` — Cancel a specific signed order
- `cancel_orders_by_nonce(min_nonce)` — Batch-cancel all orders below a nonce

**Privacy Pool:**
- `private_redeem(request, proof)` — Redeem shares privately via ZK proof
- `set_privacy_pool(privacy_pool)` — Set the privacy pool contract (admin)
- `get_privacy_pool()` — Get the privacy pool contract address

**Admin:**
- `set_inscription_fee(fee)` / `set_relayer_fee(fee)` — Configure fees (BPS)
- `set_treasury(treasury)` — Set fee recipient
- `set_registry(registry)` / `set_inscriptions_nft(nft)` — Configure NFT contracts
- `set_implementation_hash(hash)` — Set locker class hash for TBA deployment
- `set_locker_allowed_selector(locker, selector, allowed)` — Manage locker allowlist
- `pause()` / `unpause()` — Emergency controls

## SNIP-12 Typed Data

The protocol uses SNIP-12 (StarkNet's EIP-712 equivalent) for off-chain signature verification:

- **InscriptionOrder** — Signed by the borrower. Contains hashed asset arrays, counts, duration, deadline, multi_lender flag, and nonce.
- **LendOffer** — Signed by the lender. References an order hash, specifies fill percentage and optional `lender_commitment` for private lending.
- **SignedOrder** — For the matching engine. Contains maker, allowed_taker, inscription_id, bps, deadline, nonce, and min_fill_bps.

Asset arrays are hashed with `hash_assets()` (Poseidon, length-prefixed) and verified against the actual arrays in `settle()`.

## Deployment

### Declare and Deploy

```bash
# Declare the contract class
starkli declare target/dev/stela_StelaProtocol.contract_class.json \
  --account ~/.starkli-wallets/deployer/account.json \
  --keystore ~/.starkli-wallets/deployer/keystore.json

# Deploy with constructor args (owner address)
starkli deploy <CLASS_HASH> <OWNER_ADDRESS> \
  --account ~/.starkli-wallets/deployer/account.json \
  --keystore ~/.starkli-wallets/deployer/keystore.json
```

### Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| StelaProtocol (current, privacy-enabled) | `0x00c667d12113011a05f6271cc4bd9e7f4c3c5b90a093708801955af5a5b1e6d5` |
| StelaProtocol (previous) | `0x021e81956fccd8463342ff7e774bf6616b40e242fe0ea09a6f38735a604ea0e0` |
| Stela Inscriptions NFT | `0x04f2345306bf8ef1c8c1445661354ef08421aa092459445a5d6b46641237e943` |
| MockRegistry (SNIP-14) | `0x0499c5c4929b22fbf1ebd8c500f570b2ec5bd8a43a84ee63e92bf8ac7f9f422b` |

Declared class hash: `0x49ac186a5f9c92dcef69967cb1a000d634ab3892e90b6dff2d51d9580b1e827`

See `deployments/sepolia/deployedAddresses.json` for the full deployment manifest and `docs/deployment.md` for procedures.

## Security

The protocol includes guards against:
- Reentrancy on all state-mutating functions
- Double signing, double liquidation, double repayment
- Zero-percentage griefing on multi-lender inscriptions
- NFT collateral transfer bypass via selector blocklist (snake_case + camelCase)
- Fee manipulation (capped at 100%)
- Gas griefing via unbounded asset arrays (capped at 10 per type)
- SNIP-12 signature replay via NoncesComponent
- Length-extension attacks on asset hash arrays (length-prefixed Poseidon)
- Private multi-lender settlement (disallowed — one commitment per inscription)

See `docs/security.md` for the full threat model and `docs/SPEC.md` for known limitations.

## Dependencies

- StarkNet `2.13.1`
- OpenZeppelin Cairo contracts `3.0.0` (token, access, introspection, account, security)
- OpenZeppelin Cairo interfaces `2.1.0`
- OpenZeppelin Cairo utils `2.1.0`
- snforge_std `0.56.0` (dev)

## Related Repositories

- **[stela-sdk-ts](https://github.com/fepvenancio/stela-sdk-ts)** — TypeScript SDK for interacting with Stela contracts
- **[stela-app](https://github.com/fepvenancio/stela-app)** — Next.js frontend, indexer, and settlement bot
- **[stela-privacy](https://github.com/fepvenancio/stela-privacy)** — Privacy pool contract (Merkle tree, nullifier store, ZK verifier)

## License

MIT
