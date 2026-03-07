# SPEC.md -- Stela Protocol Specification

## Overview

Stela is a P2P inscriptions protocol. Any user can create an inscription (order) defining:
- What they want to borrow (debt assets)
- What they'll pay as interest (interest assets)
- What they'll lock as collateral (collateral assets)
- How long they need (duration)
- When the offer expires (deadline)

Any counterparty can fill this inscription. Once filled:
1. Collateral locks into a token-bound account (TBA) owned by the borrower's NFT
2. Debt tokens transfer from lender to borrower
3. A timelock begins (duration)
4. If the borrower repays (principal + interest) before the timelock expires, collateral is released
5. If the timelock expires without repayment, anyone can liquidate and collateral goes to lender(s)

## Inscription Types

### Standard Loan (duration > 0)
Borrower locks collateral, receives debt tokens, has `duration` seconds to repay.

### OTC Swap (duration = 0)
Instant asset exchange. No TBA is created. Collateral goes directly to the Stela contract and is marked as liquidated immediately. The lender can redeem collateral right away. This enables trustless OTC trades without a lending component.

## Multi-Asset Support

Inscriptions support multiple asset types in any combination:
- **ERC-20**: Fungible tokens (USDC, ETH, etc.)
- **ERC-721**: NFTs (collateral only, single-lender only)
- **ERC-1155**: Semi-fungible tokens (collateral only)
- **ERC-4626**: Vault shares (treated as ERC-20 for transfers)

A single inscription can have mixed collateral (e.g., 1 NFT + 1000 USDC) against mixed debt (e.g., 5000 DAI).

**Restrictions:** ERC-721 and ERC-1155 are forbidden as debt or interest assets because:
- ERC-721: non-fungible, cannot be scaled by percentage or split pro-rata
- ERC-1155: redemption functions use `IERC20Dispatcher.transfer`, which reverts on ERC-1155 contracts

ERC-721 and ERC-1155 are forbidden as collateral in multi-lender inscriptions because NFTs are indivisible.

Each asset array (debt, interest, collateral) is capped at `MAX_ASSETS = 10` to prevent gas griefing.

## Multi-Lender Support

Inscriptions can be partially filled by multiple lenders:
- Each lender specifies what percentage of the debt they want to fund (in BPS, max 10,000 = 100%)
- Each lender receives ERC-1155 shares proportional to their contribution
- Shares are redeemable after repayment or liquidation for a proportional slice of the underlying

Example: A 10,000 USDC loan can be filled by Lender A (60%) and Lender B (40%). They receive proportional ERC-1155 shares.

## Token-Bound Accounts (Lockers)

Each active inscription (duration > 0) creates a token-bound account (SNIP-14 on StarkNet). This is critical because:

1. **Proof of control**: The borrower's NFT owns the TBA, which holds the collateral. Anyone can verify on-chain that the borrower "controls" these assets.

2. **Restricted execution**: The TBA uses an allowlist-based lockdown. By default, NO outgoing calls are allowed. The protocol owner can allowlist specific selectors (e.g., vote, delegate) to let borrowers interact with locked tokens.

3. **Transferability**: The inscription NFT (which owns the TBA) is itself transferable. Borrowers can sell their debt position; lenders can sell their claim via ERC-1155 shares.

4. **Only the Stela contract can move assets**: The locker has `pull_assets` and `unlock` functions callable only by the Stela contract, used during liquidation and repayment.

## Protocol Fee

Fees are charged at settlement only (no fee at redeem). All fees are hardcoded constants:

- **Loans** (duration > 0): 25 BPS total (5 BPS relayer + 20 BPS treasury)
- **Swaps** (duration = 0): 15 BPS total (5 BPS relayer + 10 BPS treasury)

The relayer fee (5 BPS) is deducted from the lender's debt transfer and sent to the caller (relayer) to compensate for gas costs. The treasury portion is sent to the treasury address. Genesis NFT holders receive discounts on the treasury portion only (relayer fee is never discounted).

## Inscription Lifecycle -- Detailed

### 1. Create Inscription
- Caller: Borrower OR Lender (the `is_borrow` flag determines which)
- Validation:
  - `debt_assets.len() > 0` (at least one debt asset)
  - `collateral_assets.len() > 0` (at least one collateral asset)
  - `deadline > block_timestamp` (deadline must be in the future)
  - All asset arrays <= MAX_ASSETS (10)
  - All asset addresses non-zero
  - All fungible asset values > 0
  - No ERC721/ERC1155 in debt/interest
  - No ERC721/ERC1155 in collateral if multi_lender
- Computes a unique inscription ID via Poseidon hash of parameters + timestamp
- Stores the inscription in storage
- Emits `InscriptionCreated` event
- No asset transfers happen at this stage

### 2. Sign/Fill Inscription
Three entry points:
- **On-chain**: `sign_inscription(inscription_id, issued_debt_percentage)`
- **Off-chain settlement**: `settle(order, assets, sigs, offer)` -- creates + fills atomically
- **Signed order**: `fill_signed_order(order, signature, fill_bps)` -- fills an existing inscription via signed order

On first fill:
- Sets `signed_at = block_timestamp` (loan activation time)
- Sets borrower/lender addresses
- Mints an NFT to the borrower
- Creates a TBA via the SNIP-14 registry (if duration > 0)
- Records the TBA address as the locker for this inscription

On every fill:
- Validates `issued_debt_percentage` doesn't exceed remaining (total cannot exceed MAX_BPS)
- Calculates and mints ERC-1155 shares to the lender
- Calculates and mints fee shares to treasury
- Locks proportional collateral from borrower into the TBA (or directly to contract for swaps)
- Transfers proportional debt from lender to borrower
- Updates `issued_debt_percentage` on the inscription
- Emits `InscriptionSigned` event

### 3. Cancel Inscription
- Callable by the creator only (the non-zero address between borrower and lender)
- Condition: `issued_debt_percentage == 0` (inscription has not been filled at all)
- Clears asset storage maps and zeroes the inscription
- NOT paused -- creators can cancel even during emergency
- Emits `InscriptionCancelled` event

### 4. Repay
- Callable by the borrower only (`assert(caller == inscription.borrower)`)
- Conditions: inscription is active (`signed_at > 0`), not already repaid, not liquidated
- Timing: repayment window is `[signed_at, signed_at + duration]` inclusive. The borrower CAN repay exactly on the deadline. Liquidation uses strict `>` so there is no overlap.
- Pulls debt + interest from borrower to the Stela contract (proportional to `issued_debt_percentage`)
- Credits per-inscription balance tracking maps
- Marks inscription as repaid
- Unlocks collateral (TBA releases assets back to borrower)
- Emits `InscriptionRepaid` event

### 5. Liquidate
- Callable by anyone
- Conditions: `signed_at + duration` has passed (strict `>`), not repaid, not already liquidated
- Pulls collateral from the TBA to the Stela contract (scaled by `issued_debt_percentage` for fungibles)
- Credits per-inscription collateral balance tracking
- Marks inscription as liquidated
- Emits `InscriptionLiquidated` event

### 6. Redeem
- Callable by ERC-1155 share holders
- Conditions: inscription is repaid OR liquidated
- Burns caller's shares
- Deducts from total supply
- Transfers proportional assets using tracked per-inscription balances:
  - If repaid: proportional share of debt + interest tokens
  - If liquidated: proportional share of collateral tokens
- Formula: `amount = tracked_balance * shares / total_supply`
- Emits `SharesRedeemed` event

## Share Math

Shares use a virtual offset pattern (similar to ERC-4626) to prevent inflation attacks:

```
convert_to_shares(issued_debt_percentage, total_supply, current_issued_debt_percentage):
  numerator = issued_debt_percentage * (total_supply + VIRTUAL_SHARE_OFFSET)
  denominator = max(current_issued_debt_percentage, 1)
  return numerator / denominator

convert_to_percentage(shares, total_supply, current_issued_debt_percentage):
  effective_pct = max(current_issued_debt_percentage, 1)
  return shares * effective_pct / (total_supply + VIRTUAL_SHARE_OFFSET)

scale_by_percentage(value, percentage):
  return (value * percentage) / MAX_BPS

calculate_fee_shares(shares, fee_bps):
  return (shares * fee_bps) / MAX_BPS
```

## Constants

- `MAX_BPS`: 10,000 (represents 100%)
- `MAX_ASSETS`: 10 (asset array cap per type)
- `RELAYER_BPS`: 5 (0.05%, hardcoded)
- `SETTLE_TREASURY_BASE`: 20 BPS (loans, hardcoded)
- `SWAP_TREASURY_BASE`: 10 BPS (swaps, hardcoded)
- `VIRTUAL_SHARE_OFFSET`: 1e16

---

## Off-Chain SNIP-12 Signatures (settle)

The `settle()` entrypoint enables fully gasless inscription creation for both parties. A borrower signs an `InscriptionOrder` and a lender signs a `LendOffer` off-chain using SNIP-12 typed data. A relayer (any third party) submits both signatures on-chain, creating and filling the inscription in a single atomic transaction.

### InscriptionOrder (Borrower's Typed Data)

```cairo
struct InscriptionOrder {
    borrower: ContractAddress,    // Signer's address
    debt_hash: felt252,           // Poseidon hash of the debt asset array
    interest_hash: felt252,       // Poseidon hash of the interest asset array
    collateral_hash: felt252,     // Poseidon hash of the collateral asset array
    debt_count: u32,              // Expected number of debt assets
    interest_count: u32,          // Expected number of interest assets
    collateral_count: u32,        // Expected number of collateral assets
    duration: u64,                // Loan duration in seconds (0 = instant swap)
    deadline: u64,                // Unix timestamp deadline for settlement
    multi_lender: bool,           // Whether multiple lenders can partially fill
    nonce: felt252,               // Borrower's nonce for replay protection
}
```

The order commits to the loan terms by including Poseidon hashes of the asset arrays. The actual arrays are submitted separately in the `settle()` call and verified against these hashes.

### LendOffer (Lender's Typed Data)

```cairo
struct LendOffer {
    order_hash: felt252,          // SNIP-12 message hash of the InscriptionOrder
    lender: ContractAddress,      // Signer's address
    issued_debt_percentage: u256, // Fill percentage in BPS (ignored for single-lender)
    nonce: felt252,               // Lender's nonce for replay protection
}
```

The offer binds to a specific order by including its SNIP-12 message hash. The `u256` field (`issued_debt_percentage`) is encoded as a nested struct hash per SNIP-12: `Poseidon(U256_TYPE_HASH, low, high)`.

### Asset Hashing via Poseidon

The `hash_assets()` function produces a deterministic hash of an asset array:

```
hash_assets(assets):
    state = Poseidon.new()
    state = state.update(assets.length)        // length prefix prevents extension attacks
    for each asset in assets:
        state = state.update(asset.asset)       // ContractAddress
        state = state.update(asset_type_felt)   // 0=ERC20, 1=ERC721, 2=ERC1155, 3=ERC4626
        state = state.update(asset.value)       // u256
        state = state.update(asset.token_id)    // u256
    return state.finalize()
```

### `settle()` Flow

1. **Deadline check** -- `block_timestamp <= order.deadline`.
2. **Asset hash verification** -- `hash_assets(debt_assets) == order.debt_hash` (same for interest and collateral).
3. **Asset count verification** -- array lengths match the counts in the order.
4. **Asset validation** -- same rules as `create_inscription` (no zero addresses, no zero values, no NFTs in debt/interest, no NFT collateral for multi-lender).
5. **Offer binding** -- `offer.order_hash == InscriptionOrder.get_message_hash(borrower)`.
6. **Borrower signature** -- verified via `ISRC6.is_valid_signature()` on the borrower's account.
7. **Lender signature** -- verified via `ISRC6.is_valid_signature()` on the lender's account.
8. **Nonce consumption** -- borrower nonce consumed via `NoncesComponent.use_checked_nonce()`. Lender nonce consumed similarly.
9. **Inscription creation** -- a new inscription is created and filled atomically (NFT minted, TBA created if duration > 0, collateral locked, shares minted).
10. **Fee shares** -- protocol fee shares minted to treasury.
11. **Debt transfer** -- `transfer_from(lender, borrower, net_amount)` + `transfer_from(lender, relayer, fee_amount)`.
12. **Events** -- `InscriptionCreated`, `InscriptionSigned`, `OrderSettled`.

### NoncesComponent: Replay Protection

The protocol uses OpenZeppelin's `NoncesComponent` for per-address sequential nonce tracking in the `settle()` flow:

- Each address has an independent nonce counter starting at 0.
- `use_checked_nonce(address, nonce)` verifies that `nonce == current_nonce[address]`, then increments the stored nonce.
- If the nonce does not match, the call reverts with `INVALID_NONCE`.
- The current nonce for any address can be queried via `nonces(owner)`.
- Nonces are consumed for both borrower and lender on every `settle()` call.

This is separate from the `maker_min_nonce` used by the signed order matching engine (which uses a minimum-threshold model rather than sequential nonces).

---

## Signed Order Matching Engine

The signed order matching engine enables off-chain order creation with on-chain settlement. A maker creates and signs a `SignedOrder` off-chain; any taker can fill it on-chain by calling `fill_signed_order()`. This avoids the gas cost of `create_inscription` for the maker while allowing the inscription to be filled by the taker.

### SignedOrder Struct

```cairo
struct SignedOrder {
    maker: ContractAddress,       // Order creator (borrower or lender)
    allowed_taker: ContractAddress, // Zero = open to anyone; nonzero = private OTC
    inscription_id: u256,         // The inscription being offered for filling
    bps: u256,                    // Total fill percentage offered (in BPS, max 10,000)
    deadline: u64,                // Unix timestamp for order expiration
    nonce: felt252,               // Maker nonce; bump via cancel_orders_by_nonce to invalidate batch
    min_fill_bps: u256,           // Minimum acceptable partial fill (0 = any amount accepted)
}
```

The struct hash follows SNIP-12 encoding. `u256` fields are encoded as nested struct types: `Poseidon(U256_TYPE_HASH, low, high)`.

### `fill_signed_order(order, signature, fill_bps)`

Fills a signed order for `fill_bps` basis points. The flow is:

1. **Self-trade prevention** -- caller must not be the maker.
2. **Private taker check** -- if `allowed_taker` is nonzero, only that address can fill.
3. **Deadline check** -- `block_timestamp <= order.deadline`.
4. **Nonce check** -- `order.nonce >= maker_min_nonce[maker]` (enforces bulk cancellation).
5. **Cancelled check** -- the specific order hash must not be cancelled.
6. **Min fill check** -- if `order.min_fill_bps > 0`, then `fill_bps >= min_fill_bps`.
7. **Overfill check** -- `filled_amounts[order_hash] + fill_bps <= order.bps`.
8. **Lazy signature registration** -- on the first fill, verifies the maker's SNIP-12 signature via `ISRC6.is_valid_signature()` and registers the order on-chain (`signed_orders[order_hash] = true`). Subsequent fills skip signature verification.
9. **Fill execution** -- delegates to the shared `_fill_inscription()` helper (same logic as `sign_inscription`).
10. **Update filled amounts** -- `filled_amounts[order_hash] += fill_bps`.
11. **Emit `OrderFilled`** event with `inscription_id`, `order_hash`, `taker`, `fill_bps`, `total_filled_bps`.

### Partial Fills

A signed order can be partially filled by multiple takers. The maker specifies `bps` as the total amount they are willing to fill and `min_fill_bps` as the minimum per-fill.

### `cancel_order(order)`

Cancels a specific signed order. Only callable by the maker. Sets `cancelled_orders[order_hash] = true`. Emits `OrderCancelled` with `order_hash` and `maker`.

### `cancel_orders_by_nonce(min_nonce)`

Bulk cancellation. Sets `maker_min_nonce[caller] = min_nonce`. Any order with `nonce < min_nonce` becomes invalid. The new `min_nonce` must be strictly greater than the current value. Emits `OrdersBulkCancelled` with `maker` and `new_min_nonce`.

---

## View Function Reference

All view functions are read-only and do not modify state.

### Inscription Queries

| Function | Signature | Returns | Description |
|---|---|---|---|
| `get_inscription` | `(inscription_id: u256) -> StoredInscription` | `StoredInscription` | Returns the full inscription struct. Zero-initialized if not found. |
| `get_locker` | `(inscription_id: u256) -> ContractAddress` | `ContractAddress` | Returns the TBA locker address. Zero if no locker (unfilled or instant swap). |
| `convert_to_shares` | `(inscription_id: u256, issued_debt_percentage: u256) -> u256` | `u256` | Previews the number of ERC-1155 shares for a given debt percentage. |

### Signed Order Queries

| Function | Signature | Returns | Description |
|---|---|---|---|
| `is_order_registered` | `(order_hash: felt252) -> bool` | `bool` | True if the signed order has been registered (first fill completed). |
| `is_order_cancelled` | `(order_hash: felt252) -> bool` | `bool` | True if the signed order has been individually cancelled. |
| `get_filled_bps` | `(order_hash: felt252) -> u256` | `u256` | Cumulative filled BPS for a signed order. |
| `get_maker_min_nonce` | `(maker: ContractAddress) -> felt252` | `felt252` | Minimum valid nonce for a maker (orders below this are cancelled). |

### Protocol Configuration

| Function | Signature | Returns | Description |
|---|---|---|---|
| `get_treasury` | `() -> ContractAddress` | `ContractAddress` | Treasury address for protocol fee shares. |
| `is_paused` | `() -> bool` | `bool` | True if the protocol is paused. |
| `nonces` | `(owner: ContractAddress) -> felt252` | `felt252` | Current sequential nonce for an address (used for SNIP-12 signing). |
| `get_genesis_contract` | `() -> ContractAddress` | `ContractAddress` | Genesis NFT contract address (for fee discounts). |
| `get_volume_settled` | `(address: ContractAddress) -> u256` | `u256` | Settled volume for an address (used for discount tiers). |

### ERC-1155 (Inherited from OpenZeppelin)

| Function | Signature | Returns | Description |
|---|---|---|---|
| `balance_of` | `(account: ContractAddress, id: u256) -> u256` | `u256` | Share balance for `account` on inscription `id`. |
| `balance_of_batch` | `(accounts: Array<ContractAddress>, ids: Array<u256>) -> Array<u256>` | `Array<u256>` | Batch version of `balance_of`. |
| `is_approved_for_all` | `(owner: ContractAddress, operator: ContractAddress) -> bool` | `bool` | Whether `operator` is approved to manage `owner`'s shares. |
| `uri` | `(token_id: u256) -> ByteArray` | `ByteArray` | URI for a token ID (initialized to empty base URI). |

---

## All Types/Structs

### AssetType (enum)

```cairo
enum AssetType {
    ERC20,     // default
    ERC721,
    ERC1155,
    ERC4626,
}
```

### Asset

```cairo
struct Asset {
    asset: ContractAddress,    // Token contract address
    asset_type: AssetType,     // Token standard
    value: u256,               // Token amount (ERC20/ERC4626/ERC1155)
    token_id: u256,            // NFT ID (ERC721/ERC1155)
}
```

### InscriptionParams

```cairo
struct InscriptionParams {
    is_borrow: bool,                       // True if creator is borrower
    debt_assets: Array<Asset>,             // Loan principal
    interest_assets: Array<Asset>,         // Interest paid on repayment
    collateral_assets: Array<Asset>,       // Locked during loan
    duration: u64,                         // Seconds (0 = instant swap)
    deadline: u64,                         // Unix timestamp for fill expiry
    multi_lender: bool,                    // Allow partial fills
}
```

### StoredInscription

```cairo
struct StoredInscription {
    borrower: ContractAddress,             // Zero if created by lender and unfilled
    lender: ContractAddress,               // Zero if created by borrower and unfilled
    duration: u64,                         // Loan duration in seconds
    deadline: u64,                         // Fill expiry timestamp
    signed_at: u64,                        // First fill timestamp (0 if unfilled)
    issued_debt_percentage: u256,          // Cumulative BPS filled (max 10,000)
    is_repaid: bool,                       // True after borrower repays
    liquidated: bool,                      // True after liquidation (or instant swap)
    multi_lender: bool,                    // Multiple lenders allowed
    debt_asset_count: u32,                 // Number of debt assets
    interest_asset_count: u32,             // Number of interest assets
    collateral_asset_count: u32,           // Number of collateral assets
}
```

Note: Asset arrays are stored in separate indexed maps, not in this struct.

## Security Considerations

See [security.md](security.md) for the complete security model including: locker allowlist lockdown, pausable protocol, reentrancy guards, access control, asset validation rules, treasury fee system, per-inscription balance tracking, timing checks, double-action prevention, off-chain signature security, and all error codes.
