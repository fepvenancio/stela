# SHARE-MATH.md -- Stela Protocol Share Conversion Math

**File:** `src/utils/share_math.cairo`

The share system uses an ERC-4626 style virtual offset pattern to prevent first-depositor inflation attacks. Each inscription has its own share supply tracked in `total_supply: Map<u256, u256>`. The inscription ID serves as the ERC-1155 token ID.

---

## Constants

```cairo
pub const VIRTUAL_SHARE_OFFSET: u256 = 10_000_000_000_000_000; // 1e16
pub const MAX_BPS: u256 = 10_000;                               // 100%
```

---

## Functions

### convert_to_shares

Converts a debt percentage (in BPS) to the number of ERC-1155 shares to mint.

```cairo
pub fn convert_to_shares(
    issued_debt_percentage: u256,
    total_supply: u256,
    current_issued_debt_percentage: u256,
) -> u256
```

**Formula:**
```
shares = issued_debt_percentage * (total_supply + VIRTUAL_SHARE_OFFSET) / max(current_issued_debt_percentage, 1)
```

**Behavior:**
- First deposit (total_supply = 0, current_issued = 0): `shares = percentage * 1e16 / 1`
  - Example: 100% (10,000 BPS) -> 1e20 shares
- Second deposit: shares proportional to first deposit's ratio
  - Equal percentages get approximately equal shares (small difference due to virtual offset)

**Used by:** `sign_inscription()`, `settle()`, `fill_signed_order()` -- to determine how many shares to mint.

### convert_to_percentage

Converts shares back to a debt percentage (in BPS). Inverse of `convert_to_shares`.

```cairo
pub fn convert_to_percentage(
    shares: u256,
    total_supply: u256,
    current_issued_debt_percentage: u256,
) -> u256
```

**Formula:**
```
percentage = shares * max(current_issued_debt_percentage, 1) / (total_supply + VIRTUAL_SHARE_OFFSET)
```

**Note:** This function is NOT used for redemption. Redemption uses per-inscription tracked balances directly (see below).

### scale_by_percentage

Scales an asset value by a percentage (in BPS).

```cairo
pub fn scale_by_percentage(value: u256, percentage: u256) -> u256
```

**Formula:**
```
scaled = (value * percentage) / MAX_BPS
```

**Used by:** All asset transfer functions during sign/settle/repay/liquidation -- to compute the proportional amount for partial fills.

### calculate_fee_shares

Calculates the number of shares to mint to the treasury as a protocol fee.

```cairo
pub fn calculate_fee_shares(shares: u256, fee_bps: u256) -> u256
```

**Formula:**
```
fee_shares = (shares * fee_bps) / MAX_BPS
```

**Used by:** `sign_inscription()`, `settle()`, `fill_signed_order()` -- fee shares are minted to the treasury address.

---

## Per-Inscription Balance Tracking

A critical security mechanism that prevents cross-inscription drainage. Since multiple inscriptions may use the same ERC-20 token, the contract must track the actual balance attributed to each inscription independently.

### Storage

```cairo
inscription_debt_balance: Map<(u256, u32), u256>       // (inscription_id, asset_index) -> amount
inscription_interest_balance: Map<(u256, u32), u256>    // (inscription_id, asset_index) -> amount
inscription_collateral_balance: Map<(u256, u32), u256>  // (inscription_id, asset_index) -> amount
```

### When Balances Are Credited

| Function | What Gets Credited | When |
|---|---|---|
| `_pull_repayment` | `inscription_debt_balance`, `inscription_interest_balance` | Borrower repays loan |
| `_pull_collateral_from_locker` | `inscription_collateral_balance` | Inscription is liquidated |
| `_collect_collateral_for_swap` | `inscription_collateral_balance` | OTC swap (duration=0) signed |

### When Balances Are Debited

| Function | What Gets Debited | When |
|---|---|---|
| `_redeem_debt_assets` | `inscription_debt_balance` | Lender redeems after repayment |
| `_redeem_interest_assets` | `inscription_interest_balance` | Lender redeems after repayment |
| `_redeem_collateral_assets` | `inscription_collateral_balance` | Lender redeems after liquidation |

---

## Pro-Rata Redemption Formula

Redemption uses tracked per-inscription balances, NOT percentage-based scaling:

```
amount = tracked_balance * shares / total_supply
```

**Why not use `convert_to_percentage` + `scale_by_percentage`?**

The tracked balances already account for partial fills. For example, if only 60% of the inscription was filled, the tracked debt balance already contains only 60% of the original debt value. Using `convert_to_percentage` to get a BPS value and then applying `scale_by_percentage` would double-count the scaling.

### Integer Division Rounding

All division rounds DOWN (floor). This is intentionally the safe direction:
- Rounding UP (ceiling) could cause the last redeemer's transfer to exceed the tracked balance, reverting the transaction
- Any dust from rounding remains in the contract
- The last redeemer effectively receives the exact remaining tracked balance

### NFT Collateral Special Case

ERC-721 tokens cannot be split pro-rata. In `_redeem_collateral_assets`:
- If `tracked_balance > 0`, the entire NFT transfers to the first redeemer regardless of share size
- The tracked balance is set to 0 after transfer
- Subsequent redeemers get nothing for that NFT slot
- This is first-come-first-served -- inherent to NFT indivisibility

---

## Share Lifecycle Example

### Single Lender, Full Fill

```
1. Lender signs for 100% (10,000 BPS)
   shares = 10000 * (0 + 1e16) / max(0, 1) = 1e20
   fee_shares = 1e20 * 10 / 10000 = 1e17
   total_supply = 1e20 + 1e17 = 1.01e20

2. Borrower repays 1000 USDC debt + 100 DAI interest
   inscription_debt_balance[0] = 1000 USDC
   inscription_interest_balance[0] = 100 DAI

3. Lender redeems 1e20 shares (total_supply = 1.01e20)
   debt_amount = 1000 * 1e20 / 1.01e20 = 990 USDC (approx)
   interest_amount = 100 * 1e20 / 1.01e20 = 99 DAI (approx)
   [Fee shares remain -- treasury gets ~10 USDC + ~1 DAI]
```

### Multi-Lender, Partial Fills

```
1. Lender A signs for 60% (6,000 BPS)
   shares_A = 6000 * (0 + 1e16) / max(0, 1) = 6e19
   fee_A = 6e19 * 10 / 10000 = 6e16
   total_supply = 6e19 + 6e16

2. Lender B signs for 40% (4,000 BPS)
   shares_B = 4000 * (6e19 + 6e16 + 1e16) / max(6000, 1) ~ 4e19
   fee_B = 4e19 * 10 / 10000 = 4e16
   total_supply = 6e19 + 6e16 + 4e19 + 4e16

3. Borrower repays (proportional to 100% fill)
   inscription_debt_balance[0] = 1000 USDC

4. Lender A redeems 6e19 shares
   amount = 1000 * 6e19 / total_supply ~ 600 USDC

5. Lender B redeems 4e19 shares
   amount = 1000 * 4e19 / total_supply ~ 400 USDC
```

---

## Total Supply Tracking

The `total_supply` map is separate from the ERC-1155 component's internal tracking. This ensures correct pro-rata math including fee shares.

The `total_supply` is:
- Incremented by `shares + fee_shares` on each sign/settle/fill
- Decremented by `shares` on each redeem
