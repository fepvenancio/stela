# Stela Protocol -- Security Model

## Overview

Stela handles custody of user assets (ERC-20, ERC-721, ERC-1155, ERC-4626 tokens) across its lifecycle. The security model addresses collateral lockdown, access control, reentrancy protection, input validation, and fee integrity. This document describes every security mechanism present in the code.

---

## 1. Locker Allowlist Lockdown

The `LockerAccount` (`src/locker_account.cairo`) is a StarkNet account contract that holds collateral during the loan period. Its primary security mechanism is an **allowlist-based lockdown**.

### How It Works

When a locker is created, it starts in the **locked** state (`unlocked = false`). In this state:

- **`__validate__`** iterates over every `Call` in the transaction and asserts that each call's `selector` is in the `allowed_selectors` map. If any selector is not allowlisted, the entire transaction is rejected with `STELA: forbidden selector`.
- **`__execute__`** performs the same check again as defense-in-depth before forwarding calls to the target contracts.
- **`__validate_declare__`** rejects all `declare` transactions while locked, preventing deployment of arbitrary classes from the locker.

### Allowlist Management

The protocol owner controls which selectors are allowed via:

```
fn set_locker_allowed_selector(locker: ContractAddress, selector: felt252, allowed: bool)
```

This is an owner-only function on `StelaProtocol` (enforced by `self.ownable.assert_only_owner()`). Before calling the locker, it validates that the target address is a registered locker via `assert(self.is_locker.read(locker))`.

Typical allowlisted selectors would be governance functions like `vote` and `delegate`, enabling the borrower to participate in governance with locked tokens while preventing any asset movement.

### Unlocking

When the borrower repays the loan, the protocol calls `locker.unlock()`, setting `unlocked = true`. After this, the locker permits all calls -- the borrower regains full control of the collateral.

### Authorization

Only the Stela protocol contract address (stored as `stela_contract` in the locker's constructor) can call:
- `pull_assets` -- Transfer collateral from locker to Stela contract (used during liquidation).
- `unlock` -- Remove execution restrictions (used during repayment).
- `set_allowed_selector` -- Add or remove allowlisted selectors.

All three check `assert(caller == stela, Errors::UNAUTHORIZED)`.

---

## 2. Pausable Protocol

The `StelaProtocol` integrates OpenZeppelin's `PausableComponent`. The following functions check `self.pausable.assert_not_paused()` before executing:

- `create_inscription`
- `sign_inscription`
- `repay`
- `liquidate`
- `redeem`
- `settle`

### Pause/Unpause

Only the contract owner can pause or unpause:

```cairo
fn pause(ref self: ContractState) {
    self.ownable.assert_only_owner();
    self.pausable.pause();
}

fn unpause(ref self: ContractState) {
    self.ownable.assert_only_owner();
    self.pausable.unpause();
}
```

The pause status is readable via `is_paused()`.

### What Is NOT Paused

View functions (`get_inscription`, `get_locker`, `convert_to_shares`, `get_inscription_fee`, `get_treasury`, `is_paused`, `nonces`, `get_relayer_fee`) remain accessible when paused.

Admin configuration functions (`set_inscription_fee`, `set_treasury`, `set_registry`, `set_inscriptions_nft`, `set_relayer_fee`, `set_implementation_hash`, `set_locker_allowed_selector`) are also not paused -- the owner can reconfigure during an emergency.

`cancel_inscription` is also not paused, allowing creators to cancel unfilled inscriptions even during an emergency.

---

## 3. Reentrancy Guards

The `StelaProtocol` integrates OpenZeppelin's `ReentrancyGuardComponent`. The following functions are protected:

| Function | External Calls Made |
|---|---|
| `sign_inscription` | NFT mint, registry create_account, ERC-20/721/1155 transfers (collateral lock + debt issuance) |
| `repay` | ERC-20 transfer_from (debt + interest pull), locker unlock |
| `liquidate` | Locker pull_assets (triggers ERC-20/721/1155 transfers) |
| `redeem` | ERC-1155 burn, ERC-20/721/1155 transfers (asset distribution) |
| `settle` | All of the above (create + sign in one transaction) |

Each function calls `self.reentrancy_guard.start()` at the beginning and `self.reentrancy_guard.end()` at the end. If a malicious token contract attempts to re-enter any of these functions, the guard reverts.

### Functions Without Reentrancy Guard

- `create_inscription` -- Makes no external calls (only stores data and emits events).
- `cancel_inscription` -- Makes no external calls (only clears storage and emits events).
- All view functions and admin configuration functions.

---

## 4. Access Control

### Owner-Only Functions (OwnableComponent)

The contract owner (set in the constructor, transferable via OpenZeppelin's `OwnableMixinImpl`) can call:

| Function | Purpose |
|---|---|
| `set_inscription_fee(fee)` | Set the protocol fee in BPS |
| `set_treasury(treasury)` | Set the fee recipient address |
| `set_registry(registry)` | Set the SNIP-14 TBA registry address |
| `set_inscriptions_nft(nft)` | Set the inscription NFT contract address |
| `set_relayer_fee(fee)` | Set the relayer fee for off-chain settlements |
| `set_implementation_hash(hash)` | Set the LockerAccount class hash |
| `pause()` | Pause the protocol |
| `unpause()` | Unpause the protocol |
| `set_locker_allowed_selector(locker, selector, allowed)` | Configure locker allowlist |

All enforced via `self.ownable.assert_only_owner()`.

### Borrower-Only Functions

| Function | Check |
|---|---|
| `repay(inscription_id)` | `assert(caller == inscription.borrower, Errors::UNAUTHORIZED)` |

### Creator-Only Functions

| Function | Check |
|---|---|
| `cancel_inscription(inscription_id)` | `assert(caller == creator, Errors::NOT_CREATOR)` where creator is the non-zero address between borrower and lender |

### Permissionless Functions

| Function | Who Can Call | Condition |
|---|---|---|
| `create_inscription` | Anyone | Protocol not paused, valid params |
| `sign_inscription` | Anyone (counterparty) | Protocol not paused, inscription not expired, within BPS limits |
| `liquidate` | Anyone | Protocol not paused, `signed_at + duration` has passed, not repaid, not already liquidated |
| `redeem` | Any share holder | Protocol not paused, inscription is repaid or liquidated, caller has shares |
| `settle` | Anyone (relayer) | Protocol not paused, valid signatures from both parties |

---

## 5. Asset Validation Rules

### `_validate_assets` (applied to all asset arrays)

For every asset in the array:
- `asset.asset` (contract address) must not be zero: `assert(!asset.asset.is_zero(), Errors::INVALID_ADDRESS)`.
- For fungible types (ERC20, ERC4626, ERC1155): `asset.value > 0` is required: `assert(asset.value > 0, Errors::ZERO_ASSET_VALUE)`.
- ERC721 assets skip the value check (they use `token_id` instead).

### `_validate_no_nfts` (applied to debt and interest arrays, and to collateral in multi-lender mode)

Rejects any asset with `AssetType::ERC721` or `AssetType::ERC1155`:

**Why ERC-721 is forbidden in debt/interest:**
- NFTs are non-fungible and cannot be scaled by percentage for partial fills or split pro-rata for redemption.

**Why ERC-1155 is forbidden in debt/interest:**
- The redemption functions `_redeem_debt_assets` and `_redeem_interest_assets` use `IERC20Dispatcher` to transfer assets. If ERC-1155 tokens were used as debt or interest, they could be successfully created, signed, and repaid, but would permanently lock lender funds on redeem because `IERC20.transfer` would revert when called on an ERC-1155 contract.

**Why ERC-721/ERC-1155 is forbidden in multi-lender collateral:**
- NFTs are indivisible and cannot be split proportionally among multiple lenders on partial fills.

### Array Length Cap

Each asset array (debt, interest, collateral) is capped at `MAX_ASSETS = 10`:

```cairo
assert(params.debt_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
assert(params.collateral_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
assert(params.interest_assets.len() <= MAX_ASSETS, Errors::TOO_MANY_ASSETS);
```

This prevents gas griefing via unbounded loops in asset processing.

### Non-Empty Requirements

- `debt_assets` must have at least one asset: `assert(params.debt_assets.len() > 0, Errors::ZERO_DEBT_ASSETS)`.
- `collateral_assets` must have at least one asset: `assert(params.collateral_assets.len() > 0, Errors::ZERO_COLLATERAL)`.
- `interest_assets` can be empty (zero-interest loans are valid).

---

## 6. Treasury Fee System

### Protocol Fee (inscription_fee)

- Stored as `inscription_fee` in BPS. Default: 10 (0.1%).
- Applied on every `sign_inscription` and `settle` call.
- Calculated as: `fee_shares = lender_shares * inscription_fee / MAX_BPS`.
- Fee shares are minted as ERC-1155 tokens to the `treasury` address.
- The treasury can redeem these shares like any other share holder.

### Fee Cap

```cairo
fn set_inscription_fee(ref self: ContractState, fee: u256) {
    self.ownable.assert_only_owner();
    assert(fee <= MAX_BPS, Errors::FEE_TOO_HIGH);
    self.inscription_fee.write(fee);
}
```

The fee cannot exceed 10,000 BPS (100%), preventing excessive dilution.

### Relayer Fee (relayer_fee)

- Stored as `relayer_fee` in BPS. Used only in `settle` (off-chain settlement).
- Deducted from the lender's debt transfer and sent to the relayer (transaction sender).
- Calculated per debt asset: `fee_amount = total_amount * relayer_fee_bps / MAX_BPS`.
- The net amount (total minus fee) goes to the borrower; the fee goes to the relayer.

```cairo
fn set_relayer_fee(ref self: ContractState, fee: u256) {
    self.ownable.assert_only_owner();
    assert(fee <= MAX_BPS, Errors::FEE_TOO_HIGH);
    self.relayer_fee.write(fee);
}
```

### Treasury Address

- Set in the constructor (defaults to the owner address).
- Changeable via `set_treasury`, which requires a non-zero address: `assert(!treasury.is_zero(), Errors::INVALID_ADDRESS)`.

---

## 7. Per-Inscription Balance Tracking

A critical security mechanism to prevent cross-inscription drainage. Since multiple inscriptions may use the same ERC-20 token, the contract tracks the actual balance attributed to each inscription:

```
inscription_debt_balance: Map<(u256, u32), u256>
inscription_interest_balance: Map<(u256, u32), u256>
inscription_collateral_balance: Map<(u256, u32), u256>
```

**Credits happen during:**
- `_pull_repayment` -- When the borrower repays, each debt and interest asset amount is credited.
- `_pull_collateral_from_locker` -- When collateral is pulled during liquidation.
- `_collect_collateral_for_swap` -- When collateral is collected for OTC swaps.

**Debits happen during:**
- `_redeem_debt_assets` -- Pro-rata deduction: `tracked_balance - amount`.
- `_redeem_interest_assets` -- Pro-rata deduction.
- `_redeem_collateral_assets` -- Pro-rata deduction (or full zeroing for ERC-721).

**Pro-rata formula:** `amount = tracked_balance * shares / total_supply`

This is used instead of percentage-based scaling because the tracked balances already account for partial fills. Using `convert_to_percentage` would double-count the scaling.

---

## 8. Timing Checks

### Deadline (inscription expiry)

- `create_inscription`: `assert(params.deadline > timestamp, Errors::INSCRIPTION_EXPIRED)` -- Deadline must be in the future.
- `sign_inscription`: `assert(timestamp <= inscription.deadline, Errors::INSCRIPTION_EXPIRED)` -- Cannot sign after deadline.
- `settle`: `assert(timestamp <= order.deadline, Errors::ORDER_EXPIRED)` -- Cannot settle after deadline.

### Repayment Window

- Repay is valid between `signed_at` and `signed_at + duration`:
  - `assert(timestamp >= inscription.signed_at, Errors::REPAY_TOO_EARLY)`
  - `assert(timestamp <= due_to, Errors::REPAY_WINDOW_CLOSED)` where `due_to = signed_at + duration`

### Liquidation Window

- Liquidation is valid only after `signed_at + duration`:
  - `assert(timestamp > due_to, Errors::NOT_YET_LIQUIDATABLE)` where `due_to = signed_at + duration`

---

## 9. Double-Action Prevention

| Guard | Error | Purpose |
|---|---|---|
| `assert(!inscription.is_repaid, Errors::ALREADY_REPAID)` | In `repay` and `liquidate` | Prevents double repayment or liquidating a repaid loan |
| `assert(!inscription.liquidated, Errors::ALREADY_LIQUIDATED)` | In `repay` and `liquidate` | Prevents repaying a liquidated loan or double liquidation |
| `assert(inscription.signed_at > 0, Errors::INVALID_INSCRIPTION)` | In `repay` and `liquidate` | Prevents acting on unsigned inscriptions |
| `assert(inscription.issued_debt_percentage == 0, Errors::ALREADY_SIGNED)` | In `sign_inscription` (single-lender) | Prevents double-signing a single-lender inscription |
| `assert(inscription.issued_debt_percentage == 0, Errors::NOT_CANCELLABLE)` | In `cancel_inscription` | Prevents cancelling a partially or fully signed inscription |
| `assert(existing.borrower.is_zero(), Errors::INSCRIPTION_EXISTS)` | In `create_inscription` and `settle` | Prevents duplicate inscription IDs |

---

## 10. Constructor Validation

The constructor validates all inputs are non-zero:

```cairo
fn constructor(ref self: ContractState, owner, inscriptions_nft, registry, implementation_hash) {
    assert(!owner.is_zero(), Errors::INVALID_ADDRESS);
    assert(!inscriptions_nft.is_zero(), Errors::INVALID_ADDRESS);
    assert(!registry.is_zero(), Errors::INVALID_ADDRESS);
    assert(implementation_hash != 0, Errors::ZERO_IMPL_HASH);
    ...
}
```

### Admin Setter Validations

All address setters reject zero addresses:
- `set_treasury`: `assert(!treasury.is_zero(), Errors::INVALID_ADDRESS)`
- `set_registry`: `assert(!registry.is_zero(), Errors::INVALID_ADDRESS)`
- `set_inscriptions_nft`: `assert(!inscriptions_nft.is_zero(), Errors::INVALID_ADDRESS)`
- `set_implementation_hash`: `assert(implementation_hash != 0, Errors::ZERO_IMPL_HASH)`
- `set_locker_allowed_selector`: `assert(self.is_locker.read(locker), Errors::INVALID_ADDRESS)` -- additionally validates the target is a known locker.

---

## 11. Off-Chain Signature Security (settle)

### Signature Verification

Both the borrower and lender signatures are verified via the ISRC6 interface (`is_valid_signature`) on their respective account contracts. This delegates verification to the account's own logic (supporting Argent, Braavos, and other account implementations).

### Nonce Protection

Both parties' nonces are consumed via `NoncesComponent.use_checked_nonce`, preventing replay attacks. Each nonce can only be used once per address.

### Order Binding

The `LendOffer.order_hash` must equal the borrower's message hash (`order.get_message_hash(order.borrower)`). This cryptographically binds the lender's offer to the specific borrower's order.

### Asset Hash Verification

Asset arrays are not included in the signed messages directly. Instead, Poseidon hashes of each array are included in the `InscriptionOrder`. The `settle` function verifies:
- `hash_assets(debt_assets.span()) == order.debt_hash`
- `hash_assets(interest_assets.span()) == order.interest_hash`
- `hash_assets(collateral_assets.span()) == order.collateral_hash`
- `debt_assets.len() == order.debt_count`
- `interest_assets.len() == order.interest_count`
- `collateral_assets.len() == order.collateral_count`

---

## 12. Known Limitations

### NFT Collateral in Liquidation

In a liquidation scenario with ERC-721 collateral (only possible in single-lender mode since multi-lender forbids NFT collateral), the NFT is transferred to the first redeemer regardless of share size. The tracked balance is set to zero after the first redemption. This is inherent to NFT indivisibility.

### Non-Standard Token Functions

The locker's allowlist blocks known transfer selectors. Tokens with non-standard functions (e.g., custom transfer methods) could theoretically bypass the allowlist. This is documented as a known limitation.

### Partial Fill Proportionality

For multi-lender inscriptions that are not fully filled (e.g., only 60% of debt is issued), repayment and liquidation scale proportionally to the `issued_debt_percentage`. If only 60% was filled, the borrower repays 60% and only 60% of collateral is at risk.

---

## 13. Error Codes Reference

| Error Constant | Value | Triggered By |
|---|---|---|
| `INVALID_INSCRIPTION` | `'STELA: invalid inscription'` | Accessing non-existent or unsigned inscription |
| `INSCRIPTION_EXISTS` | `'STELA: inscription exists'` | Creating duplicate inscription ID |
| `INSCRIPTION_EXPIRED` | `'STELA: inscription expired'` | Creating/signing after deadline |
| `ALREADY_REPAID` | `'STELA: already repaid'` | Repaying or liquidating already-repaid inscription |
| `ALREADY_LIQUIDATED` | `'STELA: already liquidated'` | Repaying or liquidating already-liquidated inscription |
| `NOT_YET_LIQUIDATABLE` | `'STELA: not yet liquidatable'` | Liquidating before duration expires |
| `REPAY_TOO_EARLY` | `'STELA: repay too early'` | Repaying before signed_at |
| `EXCEEDS_MAX_BPS` | `'STELA: exceeds max bps'` | Filling beyond 100% |
| `NOT_REDEEMABLE` | `'STELA: not redeemable'` | Redeeming from active inscription |
| `ZERO_SHARES` | `'STELA: zero shares'` | Redeeming 0 shares or multi-lender fill with 0% |
| `UNAUTHORIZED` | `'STELA: unauthorized'` | Non-borrower calling repay, non-Stela calling locker |
| `FORBIDDEN_SELECTOR` | `'STELA: forbidden selector'` | Calling non-allowlisted selector on locked locker |
| `ZERO_DEBT_ASSETS` | `'STELA: zero debt assets'` | Creating inscription with no debt assets |
| `ZERO_COLLATERAL` | `'STELA: zero collateral'` | Creating inscription with no collateral assets |
| `NOT_CANCELLABLE` | `'STELA: not cancellable'` | Cancelling signed inscription |
| `NOT_CREATOR` | `'STELA: not creator'` | Non-creator calling cancel |
| `REPAY_WINDOW_CLOSED` | `'STELA: repay window closed'` | Repaying after duration expires |
| `NFT_ALREADY_LOCKED` | `'STELA: nft already locked'` | (Reserved for future use) |
| `ALREADY_SIGNED` | `'STELA: already signed'` | Double-signing single-lender inscription |
| `INVALID_ADDRESS` | `'STELA: invalid address'` | Zero address in constructor/setters, non-locker in set_locker_allowed_selector |
| `FEE_TOO_HIGH` | `'STELA: fee too high'` | Fee exceeds MAX_BPS |
| `ZERO_ASSET_VALUE` | `'STELA: zero asset value'` | Fungible asset with value = 0 |
| `ZERO_IMPL_HASH` | `'STELA: zero impl hash'` | Zero implementation hash |
| `NFT_NOT_FUNGIBLE` | `'STELA: nft not fungible'` | ERC721/ERC1155 in debt/interest or multi-lender collateral |
| `TOO_MANY_ASSETS` | `'STELA: too many assets'` | Asset array exceeds MAX_ASSETS (10) |
| `INVALID_SIGNATURE` | `'STELA: invalid signature'` | Failed ISRC6 signature verification in settle |
| `INVALID_NONCE` | `'STELA: invalid nonce'` | (Handled by NoncesComponent) |
| `ORDER_EXPIRED` | `'STELA: order expired'` | Settling after order deadline |
| `INVALID_ORDER` | `'STELA: invalid order'` | Asset hash/count mismatch or offer not bound to order |
| `NFT_MULTI_LENDER` | `'STELA: nft no multi lender'` | (Reserved -- validation uses NFT_NOT_FUNGIBLE) |
| `PAUSED` | `'STELA: paused'` | (Handled by PausableComponent) |
