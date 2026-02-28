# ARCHITECTURE.md -- Stela Cairo Contract Architecture

## Contracts

The protocol consists of two deployable contracts:

### StelaProtocol (`src/stela.cairo`)

The core contract. Manages the full inscription lifecycle: creation, signing, repayment, liquidation, redemption, cancellation, off-chain order settlement, signed order matching, and privacy pool integration. It is also an ERC-1155 token contract -- lender share positions are minted directly within it.

**OpenZeppelin components integrated (6):**

| Component | Purpose |
|---|---|
| `ERC1155Component` | Lender share tokens. Each inscription ID is a token ID. |
| `OwnableComponent` | Admin access control for configuration functions. |
| `PausableComponent` | Emergency pause for all state-changing operations. |
| `ReentrancyGuardComponent` | Protects `sign_inscription`, `repay`, `liquidate`, `redeem`, `settle`, `fill_signed_order`, `private_redeem`. |
| `SRC5Component` | Interface introspection (required by ERC-1155). |
| `NoncesComponent` | Per-address sequential nonces for SNIP-12 off-chain signatures in `settle()`. |

**SNIP-12 domain metadata:** name = `'Stela'`, version = `'v1'`

**Constructor:** `(owner, inscriptions_nft, registry, implementation_hash)` -- validates all non-zero, initializes ERC-1155 with empty base URI, sets default protocol fee to 10 BPS (0.1%), treasury defaults to owner.

**Constants:** `MAX_ASSETS = 10` (asset array cap per type)

### LockerAccount (`src/locker_account.cairo`)

A SNIP-14 compliant account contract (`#[starknet::contract(account)]`) that serves as a token-bound account for locking collateral. Each inscription gets its own locker deployed via the SNIP-14 registry, bound to the inscription's NFT.

**Key behavior:**
- Starts in **locked** state (`unlocked = false`). When locked, only explicitly allowlisted selectors can be called (e.g., vote, delegate).
- `__validate__` and `__execute__` both check the allowlist (defense-in-depth). `__validate_declare__` rejects declares while locked.
- After repayment, `unlock()` sets `unlocked = true` -- borrower regains full control.
- Only the Stela contract address can call `pull_assets`, `unlock`, and `set_allowed_selector`.

---

## Storage Layout

### StelaProtocol Storage (22 protocol-specific variables + 6 component substorages)

```cairo
#[storage]
struct Storage {
    // Component substorages
    erc1155: ERC1155Component::Storage,
    ownable: OwnableComponent::Storage,
    src5: SRC5Component::Storage,
    reentrancy_guard: ReentrancyGuardComponent::Storage,
    pausable: PausableComponent::Storage,
    nonces: NoncesComponent::Storage,

    // Inscription state
    inscriptions: Map<u256, StoredInscription>,

    // Asset storage (flattened arrays indexed by inscription_id and index)
    inscription_debt_assets: Map<(u256, u32), Asset>,
    inscription_interest_assets: Map<(u256, u32), Asset>,
    inscription_collateral_assets: Map<(u256, u32), Asset>,

    // Per-inscription balance tracking (prevents cross-inscription drainage)
    inscription_debt_balance: Map<(u256, u32), u256>,
    inscription_interest_balance: Map<(u256, u32), u256>,
    inscription_collateral_balance: Map<(u256, u32), u256>,

    // Locker (TBA) tracking
    lockers: Map<u256, ContractAddress>,        // inscription_id -> TBA address
    is_locker: Map<ContractAddress, bool>,       // TBA address -> registered?

    // Share tracking
    total_supply: Map<u256, u256>,               // inscription_id -> total shares

    // Protocol config
    inscription_fee: u256,                       // protocol fee in BPS (default 10)
    treasury: ContractAddress,                   // fee recipient
    inscriptions_nft: ContractAddress,            // ERC-721 NFT contract
    registry: ContractAddress,                   // SNIP-14 TBA registry
    implementation_hash: felt252,                // LockerAccount class hash
    relayer_fee: u256,                           // relayer fee in BPS for settle()

    // Signed order matching engine
    signed_orders: Map<felt252, bool>,            // order_hash -> registered?
    cancelled_orders: Map<felt252, bool>,          // order_hash -> cancelled?
    filled_amounts: Map<felt252, u256>,            // order_hash -> cumulative filled BPS
    maker_min_nonce: Map<ContractAddress, felt252>, // maker -> min valid nonce

    // Privacy pool
    privacy_pool: ContractAddress,               // zero address = disabled
}
```

### LockerAccount Storage

```cairo
#[storage]
struct Storage {
    stela_contract: ContractAddress,             // only this address can pull/unlock
    unlocked: bool,                              // false = locked, true = unrestricted
    allowed_selectors: Map<felt252, bool>,        // selector -> allowed while locked
}
```

### Design Note: Dynamic Arrays in Storage

Cairo/StarkNet storage doesn't natively support dynamic arrays in structs. Asset arrays are stored in indexed maps keyed by `(inscription_id, asset_index)`. Asset counts are stored in the `StoredInscription` struct fields (`debt_asset_count`, `interest_asset_count`, `collateral_asset_count`).

### Redemption Math

Redemption uses pro-rata share math with tracked per-inscription balances:

```
amount = tracked_balance * shares / total_supply    // CORRECT
// NOT: amount = scale_by_percentage(tracked_balance, convert_to_percentage(...))
```

The tracked balances already reflect partial fills, so using `convert_to_percentage` would double-count the scaling. Integer division rounds DOWN (floor) -- this is safe because rounding up could cause the last redeemer's transfer to exceed the tracked balance.

---

## Inscription Lifecycle Flows

### Standard Loan (duration > 0)

```
Borrower                    StelaProtocol                    Lender
   |                            |                              |
   |-- create_inscription() --->|                              |
   |   (params, NO transfers)   |                              |
   |<-- inscription_id ---------|                              |
   |                            |                              |
   |                            |<--- sign_inscription() -----|
   |                            |     (id, percentage)        |
   |                            |                              |
   |                            |--- mint NFT to borrower     |
   |                            |--- create TBA via registry  |
   |   collateral ------------->|--- lock in TBA              |
   |<-- debt tokens ------------|<-- debt from lender --------|
   |                            |--- mint shares to lender -->|
   |                            |--- mint fee to treasury     |
   |                            |                              |
   | [within signed_at + dur]   |                              |
   |--- repay() --------------->|                              |
   |   (debt + interest)        |                              |
   |                            |--- unlock TBA               |
   |                            |                              |
   |                            |<--- redeem(shares) ---------|
   |                            |--- debt + interest -------->|
```

### OTC Swap (duration = 0)

```
Borrower                    StelaProtocol                    Lender
   |                            |                              |
   |-- create_inscription() --->|  (duration = 0)             |
   |                            |                              |
   |                            |<--- sign_inscription() -----|
   |                            |                              |
   |   collateral ------------->|--- to contract (NO TBA)     |
   |<-- debt tokens ------------|<-- from lender -------------|
   |                            |--- mint shares ------------>|
   |                            |--- mark liquidated          |
   |                            |                              |
   |                            |<--- redeem(shares) ---------|
   |                            |--- collateral ------------->|
```

No TBA is created. Collateral goes directly to the Stela contract. The inscription is marked `liquidated = true` immediately, allowing the lender to redeem collateral right away.

### Off-Chain Settlement (settle)

```
Borrower       Server/API        Relayer          StelaProtocol        Lender
   |               |                |                  |                  |
   |-- sign ------>|                |                  |                  |
   | InscriptionOrder (SNIP-12)    |                  |                  |
   |               |               |                  |                  |
   |               |               |                  |<-- sign ---------|
   |               |               |                  | LendOffer        |
   |               |               |                  |   (SNIP-12)      |
   |               |               |                  |                  |
   |               |-- match ------>|                  |                  |
   |               |               |                  |                  |
   |               |               |-- settle() ----->|                  |
   |               |               | (order, assets,  |                  |
   |               |               |  sigs, offer)    |                  |
   |               |               |                  |                  |
   |               |               |  1. verify sigs  |                  |
   |               |               |  2. consume nonces                  |
   |               |               |  3. verify asset hashes             |
   |               |               |  4. create + fill inscription       |
   |               |               |  5. deduct relayer fee              |
   |<-- debt (net) |               |<-- relayer fee ---|                  |
```

Creates and fills an inscription in one atomic transaction. The relayer receives a fee deducted from the lender's debt transfer. Both borrower and lender nonces are consumed (NoncesComponent, sequential).

### Private Settlement (settle with privacy pool)

When `offer.lender_commitment != 0` and `offer.lender == zero_address`:

1. Lender pre-deposits tokens into the privacy pool
2. Lender signs a `LendOffer` with `lender_commitment` set and `lender` as zero address
3. Relayer calls `settle()` -- contract detects private mode
4. Borrower signature verified normally; lender signature and nonce skipped
5. `pool.consume_deposit(commitment)` -- one-time use
6. `pool.insert_commitment(commitment)` -- shares committed to Merkle tree
7. Debt pulled from pool (not lender) via `pool.pull_deposit_tokens()`
8. ERC-1155 shares NOT minted -- shares exist as Merkle commitments
9. `total_supply` still includes private shares for correct pro-rata math
10. Multi-lender is disallowed for private settlements

Later, the lender can `private_redeem()` with a ZK proof to claim assets without revealing identity.

### Signed Order Matching Engine (fill_signed_order)

```
Maker signs SignedOrder off-chain (SNIP-12)
  |
  v
Taker calls fill_signed_order(order, signature, fill_bps)
  1. Self-trade prevention: caller != maker
  2. Private taker check: if allowed_taker != 0, caller must match
  3. Deadline check: timestamp <= order.deadline
  4. Nonce check: order.nonce >= maker_min_nonce[maker]
  5. Cancelled check: order_hash not cancelled
  6. Min fill check: fill_bps >= min_fill_bps (if set)
  7. Overfill check: current_filled + fill_bps <= order.bps
  8. First fill: verify SNIP-12 sig, register on-chain
     Subsequent fills: skip sig verification
  9. Delegate to _fill_inscription() (same as sign_inscription)
  10. Update filled_amounts
  11. Emit OrderFilled
```

Supports partial fills. The maker specifies `bps` (total offered) and `min_fill_bps` (minimum per fill).

### Liquidation

```
Anyone calls liquidate(inscription_id)
  - Conditions: signed_at + duration has passed, not repaid, not liquidated
  - Pulls collateral from TBA to contract (scaled by issued_debt_percentage)
  - Marks inscription as liquidated
  - Lenders can then redeem shares for collateral
```

### Private Redemption

```
Anyone calls private_redeem(request, proof)
  - Privacy pool verifies ZK proof and spends nullifier
  - Shares deducted from total_supply (never were ERC-1155)
  - Assets distributed pro-rata to request.recipient
  - Emits PrivateSharesRedeemed
```

---

## All Events (15 protocol-specific)

| Event | Keyed Fields | Data Fields |
|---|---|---|
| `InscriptionCreated` | `inscription_id`, `creator` | `is_borrow` |
| `InscriptionSigned` | `inscription_id`, `borrower`, `lender` | `issued_debt_percentage`, `shares_minted` |
| `InscriptionCancelled` | `inscription_id` | `creator` |
| `InscriptionRepaid` | `inscription_id` | `repayer` |
| `InscriptionLiquidated` | `inscription_id` | `liquidator` |
| `SharesRedeemed` | `inscription_id`, `redeemer` | `shares` |
| `OrderSettled` | `inscription_id`, `borrower`, `lender` | `relayer`, `relayer_fee_amount` |
| `OrderFilled` | `inscription_id`, `order_hash`, `taker` | `fill_bps`, `total_filled_bps` |
| `OrderCancelled` | `order_hash` | `maker` |
| `OrdersBulkCancelled` | `maker` | `new_min_nonce` |
| `PrivateSettled` | `inscription_id`, `lender_commitment` | `shares_committed` |
| `PrivateSharesRedeemed` | `inscription_id`, `nullifier` | `shares`, `recipient` |

LockerAccount events:

| Event | Keyed Fields | Data Fields |
|---|---|---|
| `LockerUnlocked` | `locker` | -- |
| `AssetsPulled` | `locker` | `asset_count` |
| `AllowedSelectorUpdated` | `locker` | `selector`, `allowed` |

Plus flattened OZ component events: ERC1155Event, OwnableEvent, SRC5Event, ReentrancyGuardEvent, PausableEvent, NoncesEvent.

---

## Internal Functions

| Function | Purpose |
|---|---|
| `_fill_inscription(inscription_id, percentage, filler)` | Shared core fill logic for `sign_inscription` and `fill_signed_order`. Handles first-fill setup (NFT mint, TBA creation, signed_at), share calculation, collateral locking, debt issuance. |
| `_validate_assets(assets)` | Validates non-zero addresses and non-zero values for fungible assets. |
| `_validate_no_nfts(assets)` | Rejects ERC721/ERC1155 in debt/interest arrays (and multi-lender collateral). |
| `_compute_inscription_id(...)` | Poseidon hash of borrower, lender, duration, deadline, timestamp, and debt asset fields. Returns u256. |
| `_store_debt_assets(id, assets)` | Write debt assets to indexed storage map. |
| `_store_interest_assets(id, assets)` | Write interest assets to indexed storage map. |
| `_store_collateral_assets(id, assets)` | Write collateral assets to indexed storage map. |
| `_clear_assets(id, counts)` | Zero out all asset maps on cancellation. |
| `_collect_collateral_for_swap(...)` | Transfer collateral directly to contract for instant swaps (no TBA). Tracks balances. |
| `_lock_collateral(from, locker, id, count, pct, first)` | Transfer collateral from borrower to TBA locker. Skips ERC721 on subsequent fills. |
| `_issue_debt(from, to, id, count, pct)` | Transfer debt from lender to borrower (standard sign_inscription). |
| `_issue_debt_with_fee(from, to, relayer, id, count, pct, fee_bps)` | Transfer debt with relayer fee deduction (settle). Returns total fee. |
| `_issue_debt_from_pool(pool, to, relayer, id, count, pct, fee_bps)` | Pull debt from privacy pool to borrower + relayer (private settle). Returns total fee. |
| `_pull_repayment(from, id, debt_count, interest_count, pct)` | Pull debt + interest from borrower on repay. Credits per-inscription balances. |
| `_pull_collateral_from_locker(locker, id, count, pct)` | Pull collateral from locker on liquidation. Scales fungibles by issued_debt_percentage. Credits balances. |
| `_redeem_debt_assets(to, id, count, shares, supply)` | Pro-rata debt distribution: `tracked_balance * shares / total_supply`. |
| `_redeem_interest_assets(to, id, count, shares, supply)` | Pro-rata interest distribution. |
| `_redeem_collateral_assets(to, id, count, shares, supply)` | Pro-rata collateral distribution. NFTs are first-come-first-served (full transfer to first redeemer). |
| `_process_payment(asset, from, to, percentage)` | Single asset transfer dispatch based on AssetType. Uses `transfer` when `from == contract`, `transfer_from` otherwise. |

---

## Asset Transfer Pattern

The `_process_payment` function handles all asset movements during signing and repayment:

```
AssetType::ERC20   -> IERC20Dispatcher.transfer_from / transfer
AssetType::ERC721  -> IERC721Dispatcher.transfer_from (whole token, no scaling)
AssetType::ERC1155 -> IERC1155Dispatcher.safe_transfer_from (scaled by percentage)
AssetType::ERC4626 -> Same as ERC20 (vault shares are ERC20-compatible)
```

Each fungible payment is scaled by `percentage / MAX_BPS` via `scale_by_percentage`. ERC721 transfers the whole token (not scaled).

Redemption uses a different pattern -- `_redeem_*_assets` functions use `tracked_balance * shares / total_supply` instead of `_process_payment`, because tracked balances already account for partial fills.

---

## Inscription ID Generation

Deterministic Poseidon hash of inscription parameters:

```
inscription_id = Poseidon(
    borrower,
    lender,
    duration,
    deadline,
    block_timestamp,
    for each debt_asset: (asset_address, value, token_id)
).into()  // felt252 -> u256
```

The `block_timestamp` ensures uniqueness for repeated terms. For `settle()`, the lender is zero address in private mode, making the ID independent of lender identity.

---

## Known Constraints

1. **NFT collateral + multi-lender**: ERC721 cannot be partially transferred. The NFT moves on the first fill only; subsequent lenders share the claim. On liquidation, the first redeemer gets the entire NFT (first-come-first-served). Multi-lender inscriptions with ERC721/ERC1155 collateral are rejected at creation time.

2. **Lender field semantics**: For single-lender inscriptions, `inscription.lender` stores the actual lender. For multi-lender inscriptions, lender ownership is tracked via ERC-1155 share balances, not the `lender` field.

3. **Private settlement constraints**: Multi-lender is not supported for private settlements (one commitment per inscription). The lender address is zero in the stored inscription.

4. **Non-standard token functions**: The locker's allowlist blocks all calls by default. Tokens with non-standard transfer functions could theoretically be used for governance actions while locked, but this is by design (allowlisted selectors).

5. **ERC-1155 in debt/interest**: Forbidden because redemption functions use `IERC20Dispatcher.transfer`, which would revert on ERC-1155 contracts.
