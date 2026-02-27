# SPEC.md — Stela Protocol Specification

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
4. If the borrower repays (principal + interest) before the timelock expires → collateral is released
5. If the timelock expires without repayment → anyone can liquidate, collateral goes to lender(s)

## Inscription Types

### Standard Loan (duration > 0)
Borrower locks collateral, receives debt tokens, has `duration` seconds to repay.

### OTC Swap (duration = 0)
Instant asset exchange. The lender can unlock/claim the collateral immediately upon filling.
This enables trustless OTC trades without a lending component.

## Multi-Asset Support

Inscriptions support multiple asset types in any combination:
- **ERC-20 equivalents**: Fungible tokens (USDC, ETH, etc.)
- **ERC-721 equivalents**: NFTs
- **ERC-1155 equivalents**: Semi-fungible tokens
- **ERC-4626 equivalents**: Vault shares (treated as ERC-20 for transfers)

A single inscription can have mixed collateral (e.g., 1 NFT + 1000 USDC) against mixed debt (e.g., 5000 DAI).

## Multi-Lender Support

Inscriptions can be partially filled by multiple lenders:
- Each lender specifies what percentage of the debt they want to fund (in BPS, max 10,000 = 100%)
- Each lender receives ERC-1155 shares proportional to their contribution
- Shares are redeemable after repayment or liquidation for a proportional slice of the underlying

Example: A 10,000 USDC loan can be filled by Lender A (60%) and Lender B (40%). They receive proportional ERC-1155 shares.

## Token-Bound Accounts (Lockers)

Each active inscription creates a token-bound account (SNIP-14 on StarkNet). This is critical because:

1. **Proof of control**: The borrower's NFT owns the TBA, which holds the collateral. Anyone can verify on-chain that the borrower "controls" these assets. This matters for DAOs, treasuries, and anyone who needs to prove solvency.

2. **Restricted execution**: The TBA allows the borrower to interact with locked assets (voting with governance tokens, claiming airdrops, delegating) but BLOCKS transfers, approvals, and any action that would move assets out.

3. **Transferability**: The inscription NFT (which owns the TBA) is itself transferable. This means:
   - A borrower can sell their debt position
   - A lender can sell their claim (via ERC-1155 shares)
   - Positions can be moved to treasury contracts

4. **Only the Stela contract can move assets**: The locker has a special `pull_assets` function callable only by the Stela contract, used during repayment and liquidation.

## Protocol Fee

A small fee (configurable, default 10 BPS) is taken from lender shares and minted to the protocol treasury.

## Inscription Lifecycle — Detailed

### 1. Create Inscription
- Caller: Borrower OR Lender (the `is_borrow` flag determines which)
- Validation: debt_assets.len() > 0, duration >= 0, collateral_assets.len() > 0, deadline > now
- Computes a unique inscription ID via hash of all parameters + timestamp
- Stores the inscription in the mapping
- Emits `InscriptionCreated` event
- No asset transfers happen at this stage

### 2. Sign/Fill Inscription
Two variants:
- **On-chain**: Counterparty calls `sign_inscription(inscription_id, issued_debt_percentage)`
- **Off-chain** (future): Counterparty submits a signed inscription with the creator's signature

On first fill:
- Mints an NFT to the borrower
- Creates a TBA via the SNIP-14 registry, linked to the NFT
- Records the TBA address as the locker for this inscription

On every fill:
- Validates issued_debt_percentage doesn't exceed remaining (total can't exceed 100%)
- Mints ERC-1155 shares to the lender
- Mints fee shares to treasury
- Locks proportional collateral from borrower into the TBA
- Transfers proportional debt from lender to borrower
- Updates `issued_debt_percentage` on the inscription
- Emits `InscriptionSigned` event

### 3. Repay
- Callable by anyone (third-party repayment allowed)
- Conditions: inscription is active (past deadline, within deadline + duration), not already repaid, not liquidated
- Pulls principal + interest from caller to the Stela contract
- Marks inscription as repaid
- Unlocks collateral (TBA releases assets back to borrower)
- Emits `InscriptionRepaid` event
- Repay timing: The loan activates when sign_inscription is first called (stored as signed_at). The borrower can repay anytime between signed_at and signed_at + duration. The deadline field is ONLY for offer expiry — it has nothing to do with the repayment window. For OTC swaps (duration=0), repay is not applicable — the counterparty can claim collateral immediately after signing.
- Cancellation: The inscription creator can cancel an unfilled inscription (issued_debt_percentage == 0) anytime before someone signs it.


### 4. Liquidate
- Callable by anyone
- Conditions: deadline + duration has passed, not repaid, not already liquidated
- Pulls all collateral from the TBA to the Stela contract
- Marks inscription as liquidated
- Emits `InscriptionLiquidated` event

### 5. Redeem
- Callable by ERC-1155 share holders
- Conditions: inscription is repaid OR liquidated
- Burns caller's shares
- Transfers proportional assets:
  - If repaid: proportional share of debt + interest tokens
  - If liquidated: proportional share of collateral tokens
- Emits `SharesRedeemed` event

## Share Math

Shares use a virtual offset pattern (similar to ERC-4626) to prevent inflation attacks:

```
convertToShares(inscriptionId, issuedDebtPercentage):
  return issuedDebtPercentage * (totalSupply + 1e16) / (inscription.issuedDebtPercentage + 1)

convertToAssets(inscriptionId, shares):
  percentage = shares * (inscription.issuedDebtPercentage + 1) / (totalSupply + 1e16)
  return assets scaled by percentage
```

## Constants

- MAX_BPS: 10,000 (represents 100%)
- Default inscription fee: 10 BPS (0.1%)
- Virtual share offset: 1e16

## Security Considerations

- **Reentrancy**: All state changes before external calls. Use reentrancy guard on sign/repay/liquidate/redeem.
- **Front-running**: Inscription IDs include block.timestamp to prevent prediction.
- **Partial fills**: Must validate cumulative issued_debt_percentage never exceeds MAX_BPS.
- **Single-lender double-sign**: Single-lender inscriptions must reject a second sign_inscription call. Enforced via `assert(issued_debt_percentage == 0)` in the single-lender branch.
- **Multi-lender zero-percentage DOS**: Multi-lender `sign_inscription` must reject 0% fills to prevent griefing (triggering first-fill with no funding, permanently DOSing the inscription).
- **Selector blocklist (locker)**: OpenZeppelin Cairo registers BOTH snake_case and camelCase selectors. The locker must block all variants plus batch transfers, burns, permit, and ERC4626 vault functions.
- **Fee cap**: `set_inscription_fee` rejects fees > MAX_BPS to prevent excessive dilution.
- **Zero-address validation**: Constructor and admin setters reject zero addresses for treasury, registry, and NFT contract. Constructor also rejects zero `implementation_hash`.
- **Asset validation**: `create_inscription` rejects zero-address asset contracts, zero-value fungible assets, and ERC721/ERC1155 in debt/interest arrays (ERC721 can't be scaled/split; ERC1155 debt/interest would lock funds on redeem since redeem functions use IERC20Dispatcher).
- **Asset array cap**: Each asset array (debt, interest, collateral) capped at 10 to prevent gas griefing via unbounded loops.
- **NFT collateral fairness**: Known limitation — in multi-lender liquidation with NFT collateral, the first redeemer gets the entire NFT regardless of share size (inherent to NFT indivisibility).
- **Redemption math**: Uses pro-rata `tracked_balance * shares / total_supply`, NOT percentage-based scaling. The tracked balances already account for partial fills, so using `convert_to_percentage` would double-count.
- **Liquidation proportionality**: `_pull_collateral_from_locker` scales fungible values by `issued_debt_percentage` to match actual locked amounts. Without this, partial fill liquidation reverts.
- **Double liquidation/repayment**: Both are guarded by `already_liquidated`/`already_repaid` checks.
- **Cancel after sign**: Cancelled only if `issued_debt_percentage == 0`.
- **Weird tokens**: The locker blocks standard transfer selectors, but non-standard token functions could bypass this. Document as known limitation.
- **Duration = 0**: OTC swaps — lender gets claim on collateral immediately. Repay window is instant (signed_at to signed_at). Liquidation available at signed_at + 1.

## Signed Order Matching Engine

The signed order matching engine enables off-chain order creation with on-chain settlement. A maker creates and signs a `SignedOrder` off-chain; any taker can fill it on-chain by calling `fill_signed_order()`. This avoids the gas cost of `create_inscription` for the maker.

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
8. **Lazy signature registration** -- on the first fill, verifies the maker's SNIP-12 signature via `ISRC6.is_valid_signature()` and registers the order on-chain (`signed_orders[order_hash] = true`). Subsequent fills skip signature verification since the order is already registered.
9. **Fill execution** -- delegates to the shared `_fill_inscription()` helper (same logic as `sign_inscription`): mints ERC-1155 shares, locks collateral, transfers debt.
10. **Update filled amounts** -- `filled_amounts[order_hash] += fill_bps`.
11. **Emit `OrderFilled`** event with `inscription_id`, `order_hash`, `taker`, `fill_bps`, `total_filled_bps`.

### Partial Fills

A signed order can be partially filled by multiple takers. The maker specifies `bps` as the total amount they are willing to fill and `min_fill_bps` as the minimum per-fill. For example, an order with `bps = 10000` and `min_fill_bps = 2500` allows any number of fills as long as each is at least 25% and the total does not exceed 100%.

### `cancel_order(order)`

Cancels a specific signed order. Only callable by the maker. Sets `cancelled_orders[order_hash] = true`. Emits `OrderCancelled` with `order_hash` and `maker`.

### `cancel_orders_by_nonce(min_nonce)`

Bulk cancellation. Sets `maker_min_nonce[caller] = min_nonce`. Any order with `nonce < min_nonce` becomes invalid. The new `min_nonce` must be strictly greater than the current value to prevent no-op calls. Emits `OrdersBulkCancelled` with `maker` and `new_min_nonce`.

## Off-Chain SNIP-12 Signatures (settle)

The `settle()` entrypoint enables fully gasless inscription creation for both parties. A borrower signs an `InscriptionOrder` and a lender signs a `LendOffer` off-chain using SNIP-12 typed data. A relayer (any third party) submits both signatures on-chain, creating and filling the inscription in a single atomic transaction. The relayer receives a fee for the service.

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

This allows the borrower to commit to exact asset arrays in a single `felt252` without including the full arrays in the signed message.

### `settle()` Flow

1. **Deadline check** -- `block_timestamp <= order.deadline`.
2. **Asset hash verification** -- `hash_assets(debt_assets) == order.debt_hash` (same for interest and collateral).
3. **Asset count verification** -- array lengths match the counts in the order.
4. **Asset validation** -- same rules as `create_inscription` (no zero addresses, no zero values, no NFTs in debt/interest, no NFT collateral for multi-lender).
5. **Offer binding** -- `offer.order_hash == InscriptionOrder.get_message_hash(borrower)`.
6. **Borrower signature** -- verified via `ISRC6.is_valid_signature()` on the borrower's account.
7. **Lender signature** -- verified via `ISRC6.is_valid_signature()` on the lender's account.
8. **Nonce consumption** -- both borrower and lender nonces are consumed via `NoncesComponent.use_checked_nonce()`.
9. **Inscription creation** -- a new inscription is created and filled atomically (NFT minted, TBA created, collateral locked, debt transferred, shares minted).
10. **Relayer fee** -- for each ERC-20/ERC-4626 debt asset, `relayer_fee_bps * value / MAX_BPS` is deducted from the lender's transfer and sent to the caller (relayer). The remainder goes to the borrower.
11. **Emit `OrderSettled`** event with `inscription_id`, `borrower`, `lender`, `relayer`, `relayer_fee_amount`.

### NoncesComponent: Replay Protection

The protocol uses OpenZeppelin's `NoncesComponent` for per-address sequential nonce tracking in the `settle()` flow:

- Each address has an independent nonce counter starting at 0.
- `use_checked_nonce(address, nonce)` verifies that `nonce == current_nonce[address]`, then increments the stored nonce.
- If the nonce does not match (e.g., a replayed or out-of-order transaction), the call reverts with `INVALID_NONCE`.
- The current nonce for any address can be queried via `nonces(owner)`.
- Nonces are consumed on every `settle()` call for both the borrower and the lender, ensuring each signed order/offer can only be used once.

This is separate from the `maker_min_nonce` used by the signed order matching engine (which uses a minimum-threshold model rather than sequential nonces).

## View Function Reference

All view functions are read-only and do not modify state. They are accessible on-chain and via RPC calls.

### Inscription Queries

| Function | Signature | Returns | Description |
|---|---|---|---|
| `get_inscription` | `(inscription_id: u256) -> StoredInscription` | `StoredInscription` | Returns the full inscription struct for the given ID. Returns a zero-initialized struct if the inscription does not exist. |
| `get_locker` | `(inscription_id: u256) -> ContractAddress` | `ContractAddress` | Returns the TBA locker address for an inscription. Zero address if no locker exists (unfilled or instant swap). |
| `convert_to_shares` | `(inscription_id: u256, issued_debt_percentage: u256) -> u256` | `u256` | Previews the number of ERC-1155 shares that would be minted for a given debt percentage fill. Useful for UI display before calling `sign_inscription`. |

### Signed Order Queries

| Function | Signature | Returns | Description |
|---|---|---|---|
| `is_order_registered` | `(order_hash: felt252) -> bool` | `bool` | Returns true if the signed order has been registered on-chain (i.e., at least one fill has occurred and the maker's signature was verified). |
| `is_order_cancelled` | `(order_hash: felt252) -> bool` | `bool` | Returns true if the signed order has been explicitly cancelled via `cancel_order()`. |
| `get_filled_bps` | `(order_hash: felt252) -> u256` | `u256` | Returns the cumulative filled BPS for a signed order. 0 if never filled, up to `order.bps` when fully filled. |
| `get_maker_min_nonce` | `(maker: ContractAddress) -> felt252` | `felt252` | Returns the minimum valid nonce for a maker. Orders with `nonce < min_nonce` are considered cancelled via `cancel_orders_by_nonce()`. |

### Protocol Configuration

| Function | Signature | Returns | Description |
|---|---|---|---|
| `get_inscription_fee` | `() -> u256` | `u256` | Returns the protocol fee in BPS (default 10 = 0.1%). Applied as fee shares minted to treasury on each fill. |
| `get_relayer_fee` | `() -> u256` | `u256` | Returns the relayer fee in BPS. Deducted from debt transfers during `settle()` and sent to the relayer. |
| `get_treasury` | `() -> ContractAddress` | `ContractAddress` | Returns the treasury address that receives protocol fee shares. |
| `is_paused` | `() -> bool` | `bool` | Returns true if the protocol is paused. When paused, all state-changing operations are blocked. |
| `nonces` | `(owner: ContractAddress) -> felt252` | `felt252` | Returns the current sequential nonce for an address. Used for off-chain SNIP-12 signing to construct the correct nonce value for `settle()`. |

### ERC-1155 (Inherited from OpenZeppelin)

The StelaProtocol contract implements the full ERC-1155 interface via `ERC1155Component`. Key view functions:

| Function | Signature | Returns | Description |
|---|---|---|---|
| `balance_of` | `(account: ContractAddress, id: u256) -> u256` | `u256` | Returns the ERC-1155 share balance for `account` on inscription `id`. The inscription ID is the ERC-1155 token ID. |
| `balance_of_batch` | `(accounts: Array<ContractAddress>, ids: Array<u256>) -> Array<u256>` | `Array<u256>` | Batch version of `balance_of`. |
| `is_approved_for_all` | `(owner: ContractAddress, operator: ContractAddress) -> bool` | `bool` | Returns whether `operator` is approved to manage all of `owner`'s ERC-1155 tokens. |
| `uri` | `(token_id: u256) -> ByteArray` | `ByteArray` | Returns the URI for a token ID (initialized to empty base URI). |

### StoredInscription Struct

The `get_inscription` function returns a `StoredInscription` with the following fields:

```cairo
struct StoredInscription {
    borrower: ContractAddress,        // Zero if created by lender and unfilled
    lender: ContractAddress,          // Zero if created by borrower and unfilled
    duration: u64,                    // Loan duration in seconds (0 = instant swap)
    deadline: u64,                    // Unix timestamp for fill expiry
    signed_at: u64,                   // Timestamp of first fill (0 if unfilled)
    issued_debt_percentage: u256,     // Cumulative BPS filled (max 10,000)
    is_repaid: bool,                  // True if borrower has repaid
    liquidated: bool,                 // True if liquidated (or instant swap post-fill)
    multi_lender: bool,               // True if multiple lenders can partially fill
    debt_asset_count: u32,            // Number of debt assets
    interest_asset_count: u32,        // Number of interest assets
    collateral_asset_count: u32,      // Number of collateral assets
}
```

Note: Asset arrays are stored in separate indexed maps, not in this struct. Use the event data or indexer to retrieve individual asset details.
