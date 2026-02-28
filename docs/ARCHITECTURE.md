# Stela Protocol -- System Architecture

## Contract Overview

The protocol consists of two contracts:

### StelaProtocol (`src/stela.cairo`)

The core contract. Manages the full inscription lifecycle: creation, signing, repayment, liquidation, redemption, cancellation, and off-chain order settlement. It is also an ERC-1155 token contract -- lender share positions are minted directly within it.

**OpenZeppelin components integrated:**

| Component | Purpose |
|---|---|
| `ERC1155Component` | Lender share tokens. Each inscription ID is a token ID. |
| `OwnableComponent` | Admin access control for configuration functions. |
| `PausableComponent` | Emergency pause for all mutating operations. |
| `ReentrancyGuardComponent` | Protects `sign_inscription`, `repay`, `liquidate`, `redeem`, `settle`, and `fill_signed_order`. |
| `SRC5Component` | Interface introspection (required by ERC-1155). |
| `NoncesComponent` | Per-address nonces for SNIP-12 off-chain signatures. |

**Storage layout (protocol-specific):**

- `inscriptions: Map<u256, StoredInscription>` -- Inscription state keyed by ID.
- `inscription_debt_assets: Map<(u256, u32), Asset>` -- Debt assets indexed by (inscription_id, index).
- `inscription_interest_assets: Map<(u256, u32), Asset>` -- Interest assets indexed by (inscription_id, index).
- `inscription_collateral_assets: Map<(u256, u32), Asset>` -- Collateral assets indexed by (inscription_id, index).
- `inscription_debt_balance: Map<(u256, u32), u256>` -- Per-inscription tracked debt balance (prevents cross-inscription drainage).
- `inscription_interest_balance: Map<(u256, u32), u256>` -- Per-inscription tracked interest balance.
- `inscription_collateral_balance: Map<(u256, u32), u256>` -- Per-inscription tracked collateral balance.
- `lockers: Map<u256, ContractAddress>` -- Locker TBA address per inscription.
- `is_locker: Map<ContractAddress, bool>` -- Whether an address is a registered locker.
- `total_supply: Map<u256, u256>` -- Total ERC-1155 share supply per inscription.
- `inscription_fee: u256` -- Protocol fee in BPS (default: 10 = 0.1%).
- `relayer_fee: u256` -- Relayer fee in BPS for off-chain settlements.
- `treasury: ContractAddress` -- Fee recipient address.
- `inscriptions_nft: ContractAddress` -- ERC-721 contract for inscription NFTs.
- `registry: ContractAddress` -- SNIP-14 TBA registry contract.
- `implementation_hash: felt252` -- Class hash of LockerAccount for TBA deployment.
- `signed_orders: Map<felt252, bool>` -- Whether a signed order hash has been registered on-chain.
- `cancelled_orders: Map<felt252, bool>` -- Whether a signed order hash has been individually cancelled.
- `filled_amounts: Map<felt252, u256>` -- Cumulative filled BPS per signed order hash.
- `maker_min_nonce: Map<ContractAddress, felt252>` -- Minimum valid nonce per maker for bulk order invalidation.

### LockerAccount (`src/locker_account.cairo`)

A SNIP-14 compliant account contract (`#[starknet::contract(account)]`) that serves as a token-bound account for locking collateral. Each inscription gets its own locker deployed via the SNIP-14 registry, bound to the inscription's NFT.

**Key behavior:**

- When **locked** (default state), only explicitly allowlisted selectors can be executed via `__validate__` and `__execute__`. This lets the borrower perform actions like voting or delegating while preventing any asset transfers out.
- When **unlocked** (after repayment), all calls are permitted -- the borrower regains full control of the collateral.
- Only the Stela protocol contract can call `pull_assets`, `unlock`, and `set_allowed_selector`.
- `__validate_declare__` is rejected while locked to prevent deploying arbitrary classes.

**Storage:**

- `stela_contract: ContractAddress` -- The Stela protocol address (set in constructor).
- `unlocked: bool` -- Whether execution restrictions are removed.
- `allowed_selectors: Map<felt252, bool>` -- Allowlist of callable selectors while locked.

---

## Types

### Asset (`src/types/asset.cairo`)

```
AssetType enum:  ERC20 | ERC721 | ERC1155 | ERC4626

Asset struct:
  asset: ContractAddress     -- Token contract address
  asset_type: AssetType      -- Which token standard
  value: u256                -- Amount (ERC20/ERC1155/ERC4626) or 0 (ERC721)
  token_id: u256             -- NFT ID (ERC721/ERC1155) or 0 (ERC20/ERC4626)
```

### InscriptionParams (`src/types/inscription.cairo`)

Input struct for `create_inscription`:

```
InscriptionParams:
  is_borrow: bool                     -- true if creator is borrower, false if creator is lender
  debt_assets: Array<Asset>           -- What the borrower receives / must repay
  interest_assets: Array<Asset>       -- What the borrower pays on top of debt
  collateral_assets: Array<Asset>     -- What the borrower locks
  duration: u64                       -- Loan duration in seconds (0 = OTC swap)
  deadline: u64                       -- Unix timestamp after which the inscription can't be signed
  multi_lender: bool                  -- Whether multiple lenders can partially fill
```

### StoredInscription (`src/types/inscription.cairo`)

On-chain inscription state (scalar fields only; assets are in separate indexed maps):

```
StoredInscription:
  borrower: ContractAddress
  lender: ContractAddress
  duration: u64
  deadline: u64
  signed_at: u64                     -- Set on first sign, 0 if unsigned
  issued_debt_percentage: u256       -- BPS (0-10,000), tracks total filled percentage
  is_repaid: bool
  liquidated: bool
  multi_lender: bool
  debt_asset_count: u32
  interest_asset_count: u32
  collateral_asset_count: u32
```

### SignedOrder (`src/types/signed_order.cairo`)

Off-chain signed order for the matching engine:

```
SignedOrder:
  maker: ContractAddress          -- Order creator (borrower or lender)
  allowed_taker: ContractAddress  -- Zero = open to anyone; nonzero = private OTC fill
  inscription_id: u256            -- The inscription being offered for filling
  bps: u256                       -- Total fill percentage offered (max 10,000)
  deadline: u64                   -- Unix timestamp for order expiration
  nonce: felt252                  -- Maker nonce for bulk invalidation
  min_fill_bps: u256              -- Minimum acceptable partial fill (0 = any amount)
```

Hashed via SNIP-12 `StructHash` with Poseidon. The `u256` fields use nested struct hashes per SNIP-12: `Poseidon(U256_TYPE_HASH, low, high)`. The type hash is derived from the canonical encode_type string including the `u256` sub-type definition.

---

## Inscription Lifecycle

### 1. Create

Anyone calls `create_inscription(params)`. The caller is either the borrower (`is_borrow=true`) or the lender (`is_borrow=false`). The counterparty field is set to zero. No assets are transferred at creation -- it is purely a declaration of terms.

**Validations at creation:**
- Protocol must not be paused.
- `debt_assets` must be non-empty.
- `collateral_assets` must be non-empty.
- `deadline` must be in the future.
- Each asset array length must not exceed `MAX_ASSETS` (10).
- All assets must have non-zero contract addresses.
- Fungible assets (ERC20/ERC4626/ERC1155) must have `value > 0`.
- Debt and interest assets must not be ERC721 or ERC1155 (only ERC20/ERC4626 allowed).
- If `multi_lender` is true, collateral assets must also not be ERC721 or ERC1155.

**Inscription ID** is computed as a Poseidon hash of: borrower, lender, duration, deadline, block timestamp, and debt asset details (asset address, value, token_id for each). The contract asserts no existing inscription has that ID.

### 2. Sign (Fill)

A counterparty calls `sign_inscription(inscription_id, issued_debt_percentage)`.

- If the creator was the borrower, the caller becomes the lender.
- If the creator was the lender, the caller becomes the borrower.

**On first fill:**
1. `signed_at` is set to the current block timestamp.
2. An inscription NFT is minted to the borrower.
3. A locker TBA is created via the SNIP-14 registry (except for OTC swaps where `duration=0`).
4. Collateral is transferred from the borrower to the locker (standard loans) or to the contract (OTC swaps).

**On every fill (including first):**
1. ERC-1155 shares are minted to the lender. Fee shares are minted to treasury.
2. Debt assets are transferred from the lender to the borrower (proportional to percentage).
3. `issued_debt_percentage` is incremented by the fill amount.

**Single-lender mode:** `issued_debt_percentage` is ignored; the fill is always 100% (10,000 BPS). A second sign is rejected with `ALREADY_SIGNED`.

**Multi-lender mode:** The caller specifies `issued_debt_percentage` in BPS. Must be > 0 and the cumulative total must not exceed 10,000 BPS.

### 3. Repay

The borrower calls `repay(inscription_id)`. Must occur between `signed_at` and `signed_at + duration`.

1. Debt and interest assets are pulled from the borrower to the contract (proportional to `issued_debt_percentage`).
2. Per-inscription debt and interest balances are credited.
3. `is_repaid` is set to true.
4. The locker is unlocked (`locker.unlock()`), returning full control of collateral to the borrower.

Only the borrower can call repay (enforced by `assert(caller == inscription.borrower)`).

### 4. Liquidate

Anyone calls `liquidate(inscription_id)` after `signed_at + duration` has passed, if the loan has not been repaid.

1. `liquidated` is set to true.
2. Collateral is pulled from the locker to the contract via `locker.pull_assets()`.
3. Fungible collateral values are scaled by `issued_debt_percentage` so partial fills do not revert.
4. Per-inscription collateral balances are credited.

### 5. Redeem

Any ERC-1155 share holder calls `redeem(inscription_id, shares)`.

- **After repayment:** Shares are redeemed for pro-rata debt + interest assets.
- **After liquidation:** Shares are redeemed for pro-rata collateral assets.

Pro-rata calculation: `amount = tracked_balance * shares / total_supply`.

Shares are burned and `total_supply` is decremented. Tracked per-inscription balances are debited.

**ERC-721 collateral redemption note:** NFTs cannot be split. In a liquidation scenario, the first redeemer with any shares receives the entire NFT. The tracked balance is zeroed out to prevent double-transfer.

### 6. Cancel

The creator calls `cancel_inscription(inscription_id)`. Only possible if `issued_debt_percentage == 0` (no fills have occurred). Clears all stored asset data and zeros out the inscription record.

---

## Flow Diagrams

### Standard Loan Flow (Single Lender)

```
Borrower                    StelaProtocol                  Lender
   |                             |                            |
   |-- create_inscription ------>|                            |
   |   (is_borrow=true,         |                            |
   |    debt, collateral,       |                            |
   |    interest, duration)     |                            |
   |<--- inscription_id --------|                            |
   |                             |                            |
   |                             |<-- sign_inscription -------|
   |                             |    (inscription_id, %)     |
   |                             |                            |
   |                             |--- mint NFT to borrower    |
   |                             |--- create locker TBA       |
   |<-- debt assets ------------|--- transfer from lender ---|
   |--- collateral ------------>|--- lock in TBA             |
   |                             |--- mint ERC1155 shares --->|
   |                             |--- mint fee shares ------> Treasury
   |                             |                            |
   |        ... time passes ...  |                            |
   |                             |                            |
   |-- repay ------------------->|                            |
   |--- debt + interest -------->| (held in contract)         |
   |                             |--- unlock locker           |
   |<-- collateral returned -----|                            |
   |                             |                            |
   |                             |<-- redeem -----------------|
   |                             |--- debt + interest ------->|
   |                             |--- burn shares             |
```

### Liquidation Flow

```
Borrower                    StelaProtocol                  Anyone
   |                             |                            |
   |  ... loan duration expires  |                            |
   |  ... borrower did NOT repay |                            |
   |                             |                            |
   |                             |<-- liquidate --------------|
   |                             |--- pull collateral         |
   |                             |    from locker to contract |
   |                             |                            |
   |                             |<-- redeem ----- Lender ----|
   |                             |--- collateral ------------>|
   |                             |--- burn shares             |
```

### OTC Swap Flow (duration = 0)

```
Borrower                    StelaProtocol                  Lender
   |                             |                            |
   |-- create_inscription ------>|                            |
   |   (duration=0)             |                            |
   |                             |                            |
   |                             |<-- sign_inscription -------|
   |                             |                            |
   |                             |--- NO locker created       |
   |<-- debt assets ------------|--- from lender             |
   |--- collateral ------------>|--- to contract (tracked)   |
   |                             |--- mark as liquidated      |
   |                             |--- mint shares ----------->|
   |                             |                            |
   |                             |<-- redeem -----------------|
   |                             |--- collateral ------------>|
```

When `duration=0`, the inscription is immediately marked as `liquidated=true` on signing. No locker TBA is deployed. Collateral goes directly to the contract. The lender can redeem collateral immediately. This enables trustless atomic OTC swaps.

### Off-Chain Settlement (settle)

```
Borrower                    Relayer                    StelaProtocol                  Lender
   |                          |                             |                            |
   |-- sign InscriptionOrder  |                             |                            |
   |   (SNIP-12 off-chain) -->|                             |                            |
   |                          |                             |<-- sign LendOffer ---------|
   |                          |                             |    (SNIP-12 off-chain)     |
   |                          |                             |                            |
   |                          |-- settle ------------------>|                            |
   |                          |   (order, offer, both sigs, |                            |
   |                          |    asset arrays)            |                            |
   |                          |                             |                            |
   |                          |   ... same as sign flow ... |                            |
   |                          |   but with relayer fee      |                            |
   |                          |<-- relayer fee (from debt)  |                            |
```

The `settle` function performs the entire create + sign flow in a single transaction, using SNIP-12 off-chain signatures from both the borrower and lender. A relayer (the transaction sender) submits both signatures and receives a fee deducted from the lender's debt transfer. Nonces for both parties are consumed to prevent replay.

**Settle validations:**
- `order.deadline` must not have passed.
- Asset hashes in the order must match the provided asset arrays (verified via `hash_assets`).
- Asset counts must match.
- All standard asset validations apply (non-zero addresses, non-zero fungible values, no NFTs in debt/interest).
- Borrower signature is verified via `ISRC6.is_valid_signature` on the borrower's account.
- Lender signature is verified via `ISRC6.is_valid_signature` on the lender's account.
- The `LendOffer.order_hash` must equal the borrower's message hash.
- Both nonces are consumed via `NoncesComponent.use_checked_nonce`.

---

## Signed-Order Matching Engine

The matching engine extends the protocol with a single-signature fill model. A maker signs an order off-chain; any eligible taker can fill it on-chain without the maker submitting a transaction. This enables order-book style UX where makers post signed orders and takers execute them.

### SignedOrder Struct (`src/types/signed_order.cairo`)

```
SignedOrder:
  maker: ContractAddress          -- Order creator (borrower or lender)
  allowed_taker: ContractAddress  -- Zero = open to anyone; nonzero = private OTC
  inscription_id: u256            -- The inscription being offered for filling
  bps: u256                       -- Total fill percentage offered (in MAX_BPS units, max 10,000)
  deadline: u64                   -- Unix timestamp for order expiration
  nonce: felt252                  -- Maker nonce; bump via cancel_orders_by_nonce to batch-invalidate
  min_fill_bps: u256              -- Minimum acceptable partial fill (0 = any amount accepted)
```

The struct is hashed via SNIP-12 `StructHash` using Poseidon. The `u256` fields (`inscription_id`, `bps`, `min_fill_bps`) are encoded as nested struct hashes per the SNIP-12 specification (`Poseidon(U256_TYPE_HASH, low, high)`). The type hash is computed with `selector!()` over the canonical SNIP-12 encode_type string. **The struct layout must never change after any signature is issued** -- any field addition or reordering invalidates all outstanding signed orders.

### fill_signed_order Lifecycle

`fill_signed_order(order, signature, fill_bps)` is the primary entry point. It performs 13 sequential steps:

1. **Self-trade prevention:** `assert(caller != order.maker)` -- a maker cannot fill their own order.
2. **Private taker check:** If `order.allowed_taker` is nonzero, only that address can fill.
3. **Deadline check:** `assert(timestamp <= order.deadline)` -- order must not be expired.
4. **Hash computation:** The order hash is computed via `order.hash_struct()` for all storage lookups.
5. **Nonce check (bulk invalidation):** `order.nonce` must be >= the maker's `maker_min_nonce`. Both are cast to `u256` for comparison since `felt252` does not implement `PartialOrd`.
6. **Cancelled check:** The order must not be individually cancelled.
7. **Min fill check:** If `order.min_fill_bps > 0`, the `fill_bps` must meet or exceed it.
8. **Overfill check:** `current_filled + fill_bps` must not exceed `order.bps`.
9. **First fill -- signature verification:** On the first fill (order not yet registered), the maker's SNIP-12 signature is verified via `ISRC6.is_valid_signature` on the maker's account contract. The order is then registered on-chain (`signed_orders[order_hash] = true`).
10. **Subsequent fills -- registration check:** If the order is already registered, no signature verification is needed. The taker just submits the order struct and fill amount.
11. **Shared fill logic:** Calls `_fill_inscription(order.inscription_id, fill_bps, caller)` -- the same internal function used by `sign_inscription`.
12. **Update filled amounts:** `filled_amounts[order_hash] += fill_bps`.
13. **Emit `OrderFilled` event.**

### _fill_inscription (Shared Internal Function)

`_fill_inscription(inscription_id, issued_debt_percentage, filler)` is the shared internal function that handles the actual inscription fill. Both `sign_inscription` and `fill_signed_order` delegate to it.

**Parameters:**
- `inscription_id` -- The inscription to fill.
- `issued_debt_percentage` -- BPS amount to fill (ignored for single-lender; always 100%).
- `filler` -- The address performing the fill (caller for `sign_inscription`, caller/taker for `fill_signed_order`).

**Behavior:**
1. Loads the inscription and validates it exists and is not expired.
2. Determines the actual fill percentage (100% for single-lender, user-specified for multi-lender).
3. Determines borrower/lender roles based on which side the inscription creator occupies.
4. On first fill: sets `signed_at`, assigns borrower/lender, mints inscription NFT, creates TBA locker (unless OTC swap).
5. On every fill: calculates and mints ERC-1155 shares + fee shares, locks collateral, issues debt from lender to borrower.

This refactoring ensures that `sign_inscription` and `fill_signed_order` produce identical on-chain effects for the inscription itself.

### cancel_order

`cancel_order(order)` marks a specific order as cancelled. Only the maker can call it (`assert(caller == order.maker)`). Emits `OrderCancelled`.

### cancel_orders_by_nonce

`cancel_orders_by_nonce(min_nonce)` sets the caller's `maker_min_nonce` to the provided value, invalidating all outstanding orders with a lower nonce in a single transaction. The new value must be strictly greater than the current minimum (compared as `u256`). Emits `OrdersBulkCancelled`.

### Storage (Matching Engine)

Four new storage fields support the matching engine:

- `signed_orders: Map<felt252, bool>` -- Whether an order hash has been registered on-chain (first fill completed).
- `cancelled_orders: Map<felt252, bool>` -- Whether an order hash has been individually cancelled.
- `filled_amounts: Map<felt252, u256>` -- Cumulative filled BPS per order hash.
- `maker_min_nonce: Map<ContractAddress, felt252>` -- Minimum valid nonce per maker address. Orders with `nonce < min_nonce` are rejected.

### View Functions (Matching Engine)

| Function | Returns | Description |
|---|---|---|
| `is_order_registered(order_hash)` | `bool` | Whether the order has been registered on-chain (first fill completed). |
| `is_order_cancelled(order_hash)` | `bool` | Whether the order has been individually cancelled. |
| `get_filled_bps(order_hash)` | `u256` | Current cumulative filled BPS for the order. |
| `get_maker_min_nonce(maker)` | `felt252` | Minimum valid nonce for the maker. |

### Signed-Order Fill Flow

```
Maker                     Off-chain                  StelaProtocol                  Taker
  |                          |                             |                            |
  |-- sign SignedOrder ----->|                             |                            |
  |   (SNIP-12 off-chain)   |                             |                            |
  |                          |-- publish order + sig ----->|                            |
  |                          |   (e.g. orderbook API)      |                            |
  |                          |                             |                            |
  |                          |                             |<-- fill_signed_order -------|
  |                          |                             |    (order, sig, fill_bps)   |
  |                          |                             |                            |
  |                          |                             |--- [first fill only]        |
  |                          |                             |    verify ISRC6 signature   |
  |                          |                             |    register order on-chain  |
  |                          |                             |                            |
  |                          |                             |--- _fill_inscription        |
  |                          |                             |    (same as sign flow:      |
  |                          |                             |     mint NFT, create TBA,   |
  |                          |                             |     lock collateral,         |
  |                          |                             |     mint shares,             |
  |                          |                             |     issue debt)              |
  |                          |                             |                            |
  |                          |                             |--- update filled_amounts    |
  |                          |                             |--- emit OrderFilled         |
  |                          |                             |                            |
  |                          |                             |<-- fill_signed_order -------|
  |                          |                             |    (same order, NO sig,     |
  |                          |                             |     new fill_bps)           |
  |                          |                             |    [subsequent fill:         |
  |                          |                             |     skip sig verification]   |
```

---

## Collateral Locking Mechanism

Collateral is locked in a token-bound account (TBA) created via the SNIP-14 registry. The flow:

1. On first `sign_inscription`, the protocol calls `registry.create_account(implementation_hash, nft_contract, inscription_id)` to deploy a `LockerAccount` instance.
2. Collateral is transferred from the borrower directly to the locker address using `_lock_collateral`, which calls `_process_payment` for each collateral asset.
3. The locker is in **locked** state by default. The borrower's account owns the inscription NFT, which "owns" the locker via SNIP-14, but the locker's `__validate__` and `__execute__` reject any calls except those with allowlisted selectors.
4. The protocol owner can call `set_locker_allowed_selector` to permit specific selectors (e.g., vote, delegate) across locker instances. This function validates the target address is a known locker via `is_locker`.
5. On **repay**, the protocol calls `locker.unlock()` -- the borrower regains full control and the locker permits all calls.
6. On **liquidate**, the protocol calls `locker.pull_assets(assets)` -- collateral is transferred from the locker to the Stela contract, then redeemable by share holders.

The LockerAccount's `pull_assets` function handles all four asset types:
- **ERC20**: `IERC20Dispatcher.transfer(to, value)`
- **ERC721**: `IERC721Dispatcher.transfer_from(from, to, token_id)`
- **ERC1155**: `IERC1155Dispatcher.safe_transfer_from(from, to, token_id, value, data)`
- **ERC4626**: Treated as ERC20 (`IERC20Dispatcher.transfer(to, value)`)

### Defense in Depth

The LockerAccount checks the allowlist in both `__validate__` and `__execute__`. Even if `__validate__` is somehow bypassed, `__execute__` re-checks every call's selector against the allowlist before executing.

---

## ERC-1155 Share System

The Stela contract itself is an ERC-1155 token. Each inscription ID doubles as a token ID. When a lender signs an inscription:

1. **Lender shares** are calculated using `convert_to_shares(issued_debt_percentage, total_supply, current_issued_debt_percentage)` from `share_math.cairo`.
2. **Fee shares** are calculated as `lender_shares * inscription_fee / MAX_BPS` and minted to the treasury.
3. Both are minted via `erc1155.update()` (which skips the ERC-1155 acceptance check, allowing minting to non-contract addresses).

### Share Math (`src/utils/share_math.cairo`)

Uses an ERC-4626 style virtual offset to prevent first-depositor inflation attacks:

- **VIRTUAL_SHARE_OFFSET**: 1e16 (10,000,000,000,000,000)
- **MAX_BPS**: 10,000

**convert_to_shares:**
```
shares = issued_debt_percentage * (total_supply + VIRTUAL_SHARE_OFFSET)
         / max(current_issued_debt_percentage, 1)
```

**convert_to_percentage (inverse):**
```
percentage = shares * max(current_issued_debt_percentage, 1)
             / (total_supply + VIRTUAL_SHARE_OFFSET)
```

**scale_by_percentage:**
```
scaled_value = value * percentage / MAX_BPS
```

**calculate_fee_shares:**
```
fee_shares = shares * fee_bps / MAX_BPS
```

### Redemption

On redeem, assets are distributed pro-rata using tracked per-inscription balances:

```
amount = tracked_balance * shares / total_supply
```

This approach (rather than using BPS percentage conversion) prevents double-counting the scaling that was already applied during repayment or liquidation. The tracked balances already reflect the actual amounts received by the contract.

---

## Multi-Lender Partial Fills

When `multi_lender=true`:

1. Multiple lenders can call `sign_inscription` with different `issued_debt_percentage` values.
2. Each fill increments `inscription.issued_debt_percentage`. The sum cannot exceed 10,000 BPS.
3. Each lender receives shares proportional to their fill percentage.
4. Collateral is locked proportionally on each fill (fungible assets scaled by percentage; ERC-721 transferred only on first fill).
5. On repay, the borrower repays debt + interest scaled to the total `issued_debt_percentage`.
6. On liquidate, collateral pulled from the locker is scaled to the total `issued_debt_percentage`.

**Restriction:** Multi-lender inscriptions cannot use ERC-721 or ERC-1155 as collateral. Debt and interest always forbid ERC-721 and ERC-1155 regardless of mode -- only ERC-20 and ERC-4626 are permitted.

**Lender field semantics:** For single-lender inscriptions, `inscription.lender` stores the actual lender. For multi-lender inscriptions, this field stores the first lender only -- subsequent lender ownership is tracked entirely via ERC-1155 balances. The `inscription.lender` field is not overwritten on subsequent fills.

---

## Inscription ID Computation

IDs are deterministic Poseidon hashes of:

```
Poseidon(borrower, lender, duration, deadline, block_timestamp,
         debt_asset[0].asset, debt_asset[0].value, debt_asset[0].token_id,
         debt_asset[1].asset, debt_asset[1].value, debt_asset[1].token_id,
         ...)
```

The result (`felt252`) is cast to `u256`. The inclusion of `block_timestamp` ensures uniqueness even for identical parameters created at different times.

---

## SNIP-12 Off-Chain Signing (`src/snip12.cairo`)

Two typed data structures for gasless settlement:

### InscriptionOrder (signed by borrower)

Fields: `borrower`, `debt_hash`, `interest_hash`, `collateral_hash`, `debt_count`, `interest_count`, `collateral_count`, `duration`, `deadline`, `multi_lender`, `nonce`.

Asset arrays are not included directly -- instead, their Poseidon hashes are included. The `settle` function verifies that the provided asset arrays match the hashes via `hash_assets`.

### LendOffer (signed by lender)

Fields: `order_hash` (the borrower's message hash), `lender`, `issued_debt_percentage`, `nonce`.

The `u256` field (`issued_debt_percentage`) is encoded as a nested struct hash per the SNIP-12 specification: `Poseidon(U256_TYPE_HASH, low, high)`.

### Asset Hashing

`hash_assets(assets: Span<Asset>) -> felt252` produces a single Poseidon hash: the array length is hashed first, followed by each asset's `(asset_address, asset_type_as_felt, value, token_id)`.

Asset type encoding: `ERC20=0, ERC721=1, ERC1155=2, ERC4626=3`.

### Domain Metadata

- Name: `'Stela'`
- Version: `'v1'`

---

## Events

| Event | Emitted By | Key Fields |
|---|---|---|
| `InscriptionCreated` | `create_inscription`, `settle` | `inscription_id` (key), `creator` (key), `is_borrow` |
| `InscriptionSigned` | `sign_inscription`, `settle`, `fill_signed_order` | `inscription_id` (key), `borrower` (key), `lender` (key), `issued_debt_percentage`, `shares_minted` |
| `InscriptionCancelled` | `cancel_inscription` | `inscription_id` (key), `creator` |
| `InscriptionRepaid` | `repay` | `inscription_id` (key), `repayer` |
| `InscriptionLiquidated` | `liquidate` | `inscription_id` (key), `liquidator` |
| `SharesRedeemed` | `redeem` | `inscription_id` (key), `redeemer` (key), `shares` |
| `OrderSettled` | `settle` | `inscription_id` (key), `borrower` (key), `lender` (key), `relayer`, `relayer_fee_amount` |
| `OrderFilled` | `fill_signed_order` | `inscription_id` (key), `order_hash` (key), `taker` (key), `fill_bps`, `total_filled_bps` |
| `OrderCancelled` | `cancel_order` | `order_hash` (key), `maker` |
| `OrdersBulkCancelled` | `cancel_orders_by_nonce` | `maker` (key), `new_min_nonce` |

Locker events (emitted by LockerAccount):

| Event | Emitted By | Key Fields |
|---|---|---|
| `LockerUnlocked` | `unlock` | `locker` (key) |
| `AssetsPulled` | `pull_assets` | `locker` (key), `asset_count` |
| `AllowedSelectorUpdated` | `set_allowed_selector` | `locker` (key), `selector`, `allowed` |

---

## External Contract Dependencies

| Contract | Interface | Purpose |
|---|---|---|
| Inscription NFT | `IERC721Mintable` | ERC-721 with `mint(to, token_id)`. Minted to borrower on first sign. |
| SNIP-14 Registry | `IRegistry` | `create_account(impl_hash, token_contract, token_id) -> address`. Deploys locker TBAs. |
| LockerAccount | `ILockerAccount` | `pull_assets`, `unlock`, `set_allowed_selector`, `is_unlocked`, `is_selector_allowed`. |
| ERC-20 tokens | `IERC20Dispatcher` | `transfer`, `transfer_from` for debt, interest, and fungible collateral. |
| ERC-721 tokens | `IERC721Dispatcher` | `transfer_from` for NFT collateral. |
| ERC-1155 tokens | `IERC1155Dispatcher` | `safe_transfer_from` for semi-fungible collateral. |
| ISRC6 accounts | `ISRC6Dispatcher` | `is_valid_signature` for verifying off-chain signatures in `settle`. |

---

## Constants

| Constant | Value | Location |
|---|---|---|
| `MAX_BPS` | 10,000 | `utils/share_math.cairo` |
| `VIRTUAL_SHARE_OFFSET` | 1e16 | `utils/share_math.cairo` |
| `MAX_ASSETS` | 10 | `stela.cairo` |
| Default `inscription_fee` | 10 BPS (0.1%) | Constructor in `stela.cairo` |
