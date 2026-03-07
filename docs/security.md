# SECURITY.md -- Stela Protocol Security Model

All security mechanisms present in the StelaProtocol and LockerAccount contracts.

---

## 1. Reentrancy Guards

The `StelaProtocol` integrates OpenZeppelin's `ReentrancyGuardComponent`. Protected functions:

| Function | External Calls Made |
|---|---|
| `sign_inscription` | NFT mint, registry create_account, ERC-20/721/1155 transfers (collateral lock + debt issuance) |
| `repay` | ERC-20 transfer_from (debt + interest pull), locker unlock |
| `liquidate` | Locker pull_assets (triggers ERC-20/721/1155 transfers) |
| `redeem` | ERC-1155 burn, ERC-20/721/1155 transfers (asset distribution) |
| `settle` | All of the above (create + sign in one transaction) |
| `fill_signed_order` | ISRC6 signature verification (first fill only), then NFT mint, registry create_account, ERC-20/721/1155 transfers |

Each calls `self.reentrancy_guard.start()` at entry and `self.reentrancy_guard.end()` at exit.

**Unguarded functions** (make no external calls):
- `create_inscription` -- stores data, emits event
- `cancel_inscription` -- clears storage, emits event
- All view functions and admin configuration functions

---

## 2. Pausable Protocol

OpenZeppelin `PausableComponent`. Paused functions (check `assert_not_paused`):

- `create_inscription`
- `sign_inscription`
- `repay`
- `liquidate`
- `redeem`
- `settle`
- `fill_signed_order`

**Not paused** (always accessible):
- View functions: `get_inscription`, `get_locker`, `convert_to_shares`, `get_treasury`, `is_paused`, `nonces`, `get_genesis_contract`, `get_volume_settled`
- Admin functions: `set_treasury`, `set_registry`, `set_inscriptions_nft`, `set_implementation_hash`, `set_locker_allowed_selector`, `set_genesis_contract`
- `cancel_inscription` -- allows creators to cancel unfilled inscriptions during emergencies
- `cancel_order`, `cancel_orders_by_nonce` -- allow makers to cancel signed orders during emergencies

Only the owner can call `pause()` / `unpause()`.

---

## 3. Access Control

### Owner-Only (OwnableComponent)

| Function | Purpose |
|---|---|
| `set_treasury(treasury)` | Set fee recipient address |
| `set_registry(registry)` | Set SNIP-14 TBA registry |
| `set_inscriptions_nft(nft)` | Set inscription NFT contract |
| `set_implementation_hash(hash)` | Set LockerAccount class hash |
| `set_genesis_contract(genesis)` | Set Genesis NFT contract for fee discounts |
| `set_locker_allowed_selector(locker, selector, allowed)` | Configure locker allowlist |
| `pause()` | Pause protocol |
| `unpause()` | Unpause protocol |

All enforced via `self.ownable.assert_only_owner()`.

### Borrower-Only

| Function | Check |
|---|---|
| `repay(inscription_id)` | `assert(caller == inscription.borrower, Errors::UNAUTHORIZED)` |

### Creator-Only

| Function | Check |
|---|---|
| `cancel_inscription(inscription_id)` | `assert(caller == creator, Errors::NOT_CREATOR)` where creator is the non-zero address between borrower and lender |

### Maker-Only

| Function | Check |
|---|---|
| `cancel_order(order)` | `assert(caller == order.maker, Errors::UNAUTHORIZED)` |

### Caller-Based

| Function | Check |
|---|---|
| `cancel_orders_by_nonce(min_nonce)` | Operates on `maker_min_nonce[caller]`; any address can set its own min nonce. Must strictly increase. |

### Permissionless

| Function | Who Can Call | Condition |
|---|---|---|
| `create_inscription` | Anyone | Not paused, valid params |
| `sign_inscription` | Anyone (counterparty) | Not paused, not expired, within BPS limits |
| `liquidate` | Anyone | Not paused, `timestamp > signed_at + duration`, not repaid, not liquidated |
| `redeem` | Any share holder | Not paused, inscription is repaid or liquidated, caller has shares |
| `settle` | Anyone (relayer) | Not paused, valid signatures from both parties |
| `fill_signed_order` | Anyone (taker) | Not paused, caller != maker, caller == allowed_taker if nonzero, not expired, not cancelled, fill >= min_fill_bps, no overfill, valid signature on first fill |

---

## 4. Per-Inscription Balance Tracking

Prevents cross-inscription drainage. Since multiple inscriptions may use the same ERC-20 token, the contract tracks the actual balance attributed to each inscription:

```
inscription_debt_balance: Map<(u256, u32), u256>
inscription_interest_balance: Map<(u256, u32), u256>
inscription_collateral_balance: Map<(u256, u32), u256>
```

**Credits:**
- `_pull_repayment` -- borrower repays debt + interest
- `_pull_collateral_from_locker` -- collateral pulled during liquidation
- `_collect_collateral_for_swap` -- collateral collected for OTC swap (duration=0)

**Debits:**
- `_redeem_debt_assets` -- pro-rata deduction on redemption
- `_redeem_interest_assets` -- pro-rata deduction on redemption
- `_redeem_collateral_assets` -- pro-rata deduction (or full zeroing for ERC-721)

**Redemption formula:** `amount = tracked_balance * shares / total_supply`

This is used instead of percentage-based scaling because tracked balances already account for partial fills. Using `convert_to_percentage` + `scale_by_percentage` would double-count the scaling.

---

## 5. Locker Allowlist Lockdown

The `LockerAccount` is a SNIP-14 token-bound account that holds collateral. It uses an **allowlist** model (not a blocklist).

### Locked State (default)

When created, the locker starts locked (`unlocked = false`):

- **`__validate__`** checks every `Call` selector against `allowed_selectors` map. Non-allowlisted selectors revert with `STELA: forbidden selector`.
- **`__execute__`** performs the same check as defense-in-depth.
- **`__validate_declare__`** rejects all `declare` transactions while locked.

### Allowlist Management

The protocol owner controls which selectors are allowed:

```cairo
fn set_locker_allowed_selector(locker: ContractAddress, selector: felt252, allowed: bool)
```

Owner-only. Validates the target is a registered locker via `assert(self.is_locker.read(locker))`. Typical allowlisted selectors: `vote`, `delegate` (governance participation with locked collateral).

### Unlocking

When the borrower repays, the protocol calls `locker.unlock()`, setting `unlocked = true`. After this, the locker permits all calls.

### Authorization

Only the Stela protocol contract (stored as `stela_contract` in the locker constructor) can call:
- `pull_assets` -- transfer collateral from locker to Stela (liquidation)
- `unlock` -- remove restrictions (repayment)
- `set_allowed_selector` -- manage allowlist

All three check `assert(caller == stela, Errors::UNAUTHORIZED)`.

---

## 6. ERC-721 First-Come-First-Served Limitation

ERC-721 tokens cannot be split pro-rata. In `_redeem_collateral_assets`:
- If `tracked_balance > 0`, the entire NFT transfers to the first redeemer regardless of share size
- The tracked balance is set to 0 after transfer
- Subsequent redeemers get nothing for that NFT slot

This only applies in single-lender mode (ERC-721/ERC-1155 collateral is forbidden in multi-lender inscriptions).

---

## 7. Dual Nonce Systems

### Sequential Nonces (NoncesComponent) -- for `settle()`

Both borrower and lender nonces are consumed via `NoncesComponent.use_checked_nonce`. This uses an EQUALITY check (`nonce == current`), not a threshold check. Each nonce can only be used once per address.

### Threshold Nonces (maker_min_nonce) -- for `fill_signed_order()`

`cancel_orders_by_nonce(min_nonce)` sets `maker_min_nonce[caller] = min_nonce`. Orders with `nonce < min_nonce` are rejected. The `min_nonce` must strictly increase (`min_nonce > current`).

Individual cancellation: `cancel_order(order)` sets `cancelled_orders[order_hash] = true`.

---

## 8. Asset Validation Rules

### `_validate_assets` (all arrays)

- `asset.asset` must not be zero address
- For fungible types (ERC20, ERC4626, ERC1155): `asset.value > 0`
- ERC721 skips value check (uses `token_id` instead)

### `_validate_no_nfts` (debt, interest, multi-lender collateral)

Rejects `AssetType::ERC721` and `AssetType::ERC1155`:

- **Debt/interest**: ERC-721/1155 cannot be scaled by percentage. Also, redemption uses `IERC20Dispatcher` which would revert on non-ERC20 contracts.
- **Multi-lender collateral**: NFTs are indivisible, cannot be split among multiple lenders.

### Array Length Cap

Each array capped at `MAX_ASSETS = 10`. Prevents gas griefing via unbounded loops.

### Non-Empty Requirements

- `debt_assets`: at least 1 (`ZERO_DEBT_ASSETS`)
- `collateral_assets`: at least 1 (`ZERO_COLLATERAL`)
- `interest_assets`: can be empty (zero-interest loans)

---

## 9. Off-Chain Signature Security

### settle() -- SNIP-12 Typed Data

- Both borrower and lender signatures verified via ISRC6 `is_valid_signature`
- Nonces consumed via `NoncesComponent` (sequential, one-time use)
- `LendOffer.order_hash` must equal the borrower's message hash (cryptographic binding)
- Asset hashes verified: `hash_assets(actual) == order.{debt,interest,collateral}_hash`
- Asset counts verified: `actual.len() == order.{debt,interest,collateral}_count`

### fill_signed_order() -- Lazy Registration

- First fill: SNIP-12 signature verified, order registered on-chain (`signed_orders[hash] = true`)
- Subsequent fills: skip signature verification (on-chain registration is proof of authorization)
- Self-trade prevention: `assert(caller != order.maker)`
- Private taker: if `order.allowed_taker != 0`, only that address can fill
- Minimum fill enforcement: `fill_bps >= min_fill_bps`
- Overfill prevention: `filled + fill_bps <= order.bps`

---

## 10. Timing Checks

### Deadline (inscription expiry)

- `create_inscription`: `deadline > block_timestamp`
- `sign_inscription`: `block_timestamp <= deadline`
- `settle`: `block_timestamp <= order.deadline`
- `fill_signed_order`: `block_timestamp <= order.deadline` AND `block_timestamp <= inscription.deadline`

### Repayment Window

- Valid between `signed_at` and `signed_at + duration` (inclusive both ends)
- `assert(timestamp >= signed_at, REPAY_TOO_EARLY)`
- `assert(timestamp <= signed_at + duration, REPAY_WINDOW_CLOSED)`

### Liquidation Window

- Valid only after `signed_at + duration` (strictly greater)
- `assert(timestamp > signed_at + duration, NOT_YET_LIQUIDATABLE)`

---

## 11. Double-Action Prevention

| Guard | Error | Purpose |
|---|---|---|
| `!inscription.is_repaid` | `ALREADY_REPAID` | In `repay` and `liquidate` |
| `!inscription.liquidated` | `ALREADY_LIQUIDATED` | In `repay` and `liquidate` |
| `inscription.signed_at > 0` | `INVALID_INSCRIPTION` | In `repay` and `liquidate` |
| `inscription.issued_debt_percentage == 0` | `ALREADY_SIGNED` | In single-lender `sign_inscription` |
| `inscription.issued_debt_percentage == 0` | `NOT_CANCELLABLE` | In `cancel_inscription` |
| `existing.borrower.is_zero()` / `existing.lender.is_zero()` | `INSCRIPTION_EXISTS` | In `create_inscription` and `settle` |
| `filled + fill_bps <= order.bps` | `OVERFILL` | In `fill_signed_order` |
| `!cancelled_orders[hash]` | `ORDER_CANCELLED` | In `fill_signed_order` |
| `nonce >= maker_min_nonce` | `INVALID_NONCE` | In `fill_signed_order` |
| `min_nonce > current_min` | `INVALID_NONCE` | In `cancel_orders_by_nonce` |

---

## 12. Constructor and Setter Validations

### Constructor

All inputs validated non-zero:
- `owner`: `!is_zero()` (`INVALID_ADDRESS`)
- `inscriptions_nft`: `!is_zero()` (`INVALID_ADDRESS`)
- `registry`: `!is_zero()` (`INVALID_ADDRESS`)
- `implementation_hash`: `!= 0` (`ZERO_IMPL_HASH`)

### Admin Setters

- `set_treasury`: `!treasury.is_zero()` (`INVALID_ADDRESS`)
- `set_registry`: `!registry.is_zero()` (`INVALID_ADDRESS`)
- `set_inscriptions_nft`: `!inscriptions_nft.is_zero()` (`INVALID_ADDRESS`)
- `set_implementation_hash`: `implementation_hash != 0` (`ZERO_IMPL_HASH`)
- `set_locker_allowed_selector`: `self.is_locker.read(locker)` (`INVALID_ADDRESS`)
- `set_genesis_contract`: no validation (zero address disables discounts)

---

## 13. Known Limitations

### NFT Collateral Redemption
In single-lender mode with ERC-721 collateral and fee shares, the NFT goes to the first redeemer. The treasury (holding fee shares) may get nothing for that NFT slot. Inherent to NFT indivisibility.

### Non-Standard Token Functions
The locker allowlist blocks known transfer selectors. Tokens with non-standard transfer methods could theoretically bypass the allowlist.

### Partial Fill Proportionality
For multi-lender inscriptions not fully filled, repayment and liquidation scale proportionally to `issued_debt_percentage`. If 60% filled, borrower repays 60% and 60% of collateral is at risk.

---

## 14. Error Codes Reference

| Error Constant | Value | Triggered By |
|---|---|---|
| `INVALID_INSCRIPTION` | `'STELA: invalid inscription'` | Non-existent or unsigned inscription |
| `INSCRIPTION_EXISTS` | `'STELA: inscription exists'` | Duplicate inscription ID |
| `INSCRIPTION_EXPIRED` | `'STELA: inscription expired'` | Creating/signing after deadline |
| `ALREADY_REPAID` | `'STELA: already repaid'` | Double repayment or liquidating repaid loan |
| `ALREADY_LIQUIDATED` | `'STELA: already liquidated'` | Repaying or double-liquidating |
| `NOT_YET_LIQUIDATABLE` | `'STELA: not yet liquidatable'` | Liquidating before duration expires |
| `REPAY_TOO_EARLY` | `'STELA: repay too early'` | Repaying before signed_at |
| `REPAY_WINDOW_CLOSED` | `'STELA: repay window closed'` | Repaying after duration expires |
| `EXCEEDS_MAX_BPS` | `'STELA: exceeds max bps'` | Filling beyond 100% |
| `NOT_REDEEMABLE` | `'STELA: not redeemable'` | Redeeming from active inscription |
| `ZERO_SHARES` | `'STELA: zero shares'` | Redeeming 0 shares or 0% fill |
| `UNAUTHORIZED` | `'STELA: unauthorized'` | Non-borrower repay, non-Stela locker call, non-maker cancel |
| `FORBIDDEN_SELECTOR` | `'STELA: forbidden selector'` | Non-allowlisted selector on locked locker |
| `ZERO_DEBT_ASSETS` | `'STELA: zero debt assets'` | No debt assets |
| `ZERO_COLLATERAL` | `'STELA: zero collateral'` | No collateral assets |
| `NOT_CANCELLABLE` | `'STELA: not cancellable'` | Cancelling signed inscription |
| `NOT_CREATOR` | `'STELA: not creator'` | Non-creator cancel |
| `NFT_ALREADY_LOCKED` | `'STELA: nft already locked'` | (Reserved) |
| `ALREADY_SIGNED` | `'STELA: already signed'` | Double-signing single-lender |
| `INVALID_ADDRESS` | `'STELA: invalid address'` | Zero address, non-locker in set_locker_allowed_selector |
| `ZERO_ASSET_VALUE` | `'STELA: zero asset value'` | Fungible asset with value = 0 |
| `ZERO_IMPL_HASH` | `'STELA: zero impl hash'` | Zero implementation hash |
| `NFT_NOT_FUNGIBLE` | `'STELA: nft not fungible'` | ERC721/ERC1155 in debt/interest or multi-lender collateral |
| `TOO_MANY_ASSETS` | `'STELA: too many assets'` | Array exceeds MAX_ASSETS (10) |
| `INVALID_SIGNATURE` | `'STELA: invalid signature'` | Failed ISRC6 signature verification |
| `INVALID_NONCE` | `'STELA: invalid nonce'` | Nonce mismatch (settle), below min (fill), non-increasing (cancel_by_nonce) |
| `ORDER_EXPIRED` | `'STELA: order expired'` | Settling/filling after deadline |
| `INVALID_ORDER` | `'STELA: invalid order'` | Asset hash/count mismatch, offer not bound to order |
| `NFT_MULTI_LENDER` | `'STELA: nft no multi lender'` | (Reserved -- uses NFT_NOT_FUNGIBLE) |
| `ORDER_CANCELLED` | `'STELA: order cancelled'` | Filling individually cancelled order |
| `UNAUTHORIZED_TAKER` | `'STELA: unauthorized taker'` | Caller not allowed_taker |
| `OVERFILL` | `'STELA: overfill'` | Fill exceeds order total BPS |
| `SELF_TRADE_NOT_ALLOWED` | `'STELA: self trade'` | Maker filling own order |
| `ORDER_NOT_REGISTERED` | `'STELA: order not registered'` | (Defensive assertion) |
| `MIN_FILL_NOT_MET` | `'STELA: min fill not met'` | Fill below min_fill_bps |
