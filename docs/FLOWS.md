# FLOWS.md -- Stela Protocol Flow Diagrams

Step-by-step flow diagrams for every protocol operation.

---

## 1. Standard Loan Flow (duration > 0)

### Create -> Sign -> Repay -> Redeem

```
Borrower                     StelaProtocol                     Lender
   |                              |                              |
   |--- create_inscription() ---->|                              |
   |    params: {                 |                              |
   |      is_borrow: true,        |                              |
   |      debt_assets,            |                              |
   |      interest_assets,        |                              |
   |      collateral_assets,      |                              |
   |      duration, deadline,     |                              |
   |      multi_lender            |                              |
   |    }                         |                              |
   |<--- inscription_id ---------|                              |
   |    [InscriptionCreated]      |                              |
   |    NO ASSET TRANSFERS        |                              |
   |                              |                              |
   |                              |<--- sign_inscription() -----|
   |                              |     (inscription_id, pct)   |
   |                              |                              |
   |                              |  1. Validate not expired     |
   |                              |  2. Validate BPS limits      |
   |                              |  3. Set signed_at = now      |
   |                              |  4. Mint NFT to borrower     |
   |                              |  5. Create TBA via registry  |
   |   collateral --------------->|  6. Lock in TBA              |
   |<-- debt tokens --------------|<-- transfer_from lender -----|
   |                              |  7. Mint shares to lender -->|
   |                              |  8. Mint fee to treasury     |
   |                              |     [InscriptionSigned]      |
   |                              |                              |
   | [signed_at <= now <= signed_at + duration]                  |
   |                              |                              |
   |--- repay() ---------------->|                              |
   |   debt + interest --------->|  1. Validate borrower         |
   |                              |  2. Validate timing window   |
   |                              |  3. Pull debt + interest     |
   |                              |  4. Credit tracked balances  |
   |                              |  5. Mark is_repaid = true    |
   |                              |  6. Unlock TBA               |
   |                              |     [InscriptionRepaid]      |
   |   collateral unlocked <-----|                              |
   |                              |                              |
   |                              |<--- redeem(shares) ---------|
   |                              |  1. Validate redeemable      |
   |                              |  2. Burn shares              |
   |                              |  3. Pro-rata: balance *      |
   |                              |     shares / total_supply    |
   |                              |  4. Transfer debt + interest |
   |                              |--- debt + interest -------->|
   |                              |     [SharesRedeemed]         |
```

### Key timing rules:
- **Deadline**: inscription must be signed before `deadline`
- **Repay window**: `signed_at` to `signed_at + duration` (inclusive on both ends)
- **Liquidation window**: after `signed_at + duration` (strict >)

---

## 2. Liquidation Flow

```
Anyone                       StelaProtocol                     Lender
   |                              |                              |
   | [signed_at + duration has passed, loan not repaid]          |
   |                              |                              |
   |--- liquidate() ------------>|                              |
   |    (inscription_id)          |                              |
   |                              |  1. Validate not repaid      |
   |                              |  2. Validate not liquidated  |
   |                              |  3. Validate signed_at > 0   |
   |                              |  4. Validate timestamp >     |
   |                              |     signed_at + duration     |
   |                              |  5. Mark liquidated = true   |
   |                              |  6. Pull collateral from TBA |
   |                              |     (scaled by issued_pct)   |
   |                              |  7. Credit collateral balance|
   |                              |     [InscriptionLiquidated]  |
   |                              |                              |
   |                              |<--- redeem(shares) ---------|
   |                              |  1. Pro-rata collateral      |
   |                              |--- collateral ------------->|
   |                              |     [SharesRedeemed]         |
```

---

## 3. OTC Swap Flow (duration = 0)

```
Borrower                     StelaProtocol                     Lender
   |                              |                              |
   |--- create_inscription() ---->|                              |
   |    duration: 0               |                              |
   |                              |                              |
   |                              |<--- sign_inscription() -----|
   |                              |                              |
   |   collateral --------------->|  -> contract (NO TBA)       |
   |<-- debt tokens --------------|<-- from lender -------------|
   |                              |  Mint shares to lender ----->|
   |                              |  Mark liquidated = true      |
   |                              |     [InscriptionSigned]      |
   |                              |                              |
   |                              |<--- redeem(shares) ---------|
   |                              |--- collateral ------------->|
   |                              |     [SharesRedeemed]         |
```

- No TBA created -- collateral goes directly to Stela contract
- Inscription marked `liquidated = true` immediately
- Lender can redeem collateral right away
- No repayment step exists

---

## 4. Multi-Lender Flow

```
Borrower                     StelaProtocol                Lender A   Lender B
   |                              |                          |          |
   |--- create_inscription() ---->|                          |          |
   |    multi_lender: true        |                          |          |
   |                              |                          |          |
   |                              |<-- sign(id, 6000 BPS) --|          |
   |                              |  First fill:             |          |
   |                              |  1. signed_at = now      |          |
   |                              |  2. Mint NFT             |          |
   |                              |  3. Create TBA           |          |
   |  60% collateral ----------->|  4. Lock 60% collateral  |          |
   |<- 60% debt -----------------|<- 60% from Lender A -----|          |
   |                              |  5. Mint shares -------->|          |
   |                              |  issued_pct = 6000       |          |
   |                              |                          |          |
   |                              |<-- sign(id, 4000 BPS) --|----------|
   |                              |  Subsequent fill:        |          |
   |  40% collateral ----------->|  1. Lock 40% collateral  |          |
   |<- 40% debt -----------------|<- 40% from Lender B -----|----------|
   |                              |  2. Mint shares -------->|--------->|
   |                              |  issued_pct = 10000      |          |
   |                              |                          |          |
   |--- repay() ---------------->|                          |          |
   |  100% debt + interest ----->|                          |          |
   |                              |                          |          |
   |                              |<-- redeem(shares) ------|          |
   |                              |-- 60% of debt+int ----->|          |
   |                              |                          |          |
   |                              |<-- redeem(shares) ------|----------|
   |                              |-- 40% of debt+int ----->|--------->|
```

**Key points:**
- ERC721 collateral moves on first fill only (indivisible)
- Each lender's shares are proportional to their fill percentage
- Redemption is pro-rata: `tracked_balance * shares / total_supply`
- The `lender` field in StoredInscription is NOT meaningful for multi-lender -- use ERC-1155 balances

---

## 5. Off-Chain Settlement Flow (settle)

```
Step 1: Borrower signs InscriptionOrder off-chain (SNIP-12)
   - Includes Poseidon hashes of asset arrays
   - Includes sequential nonce from NoncesComponent

Step 2: Borrower posts order to API server (POST /api/orders)
   - Server verifies signature, stores in D1 database

Step 3: Lender browses orders, signs LendOffer off-chain (SNIP-12)
   - offer.order_hash = InscriptionOrder message hash
   - Includes sequential nonce
   - Lender approves Stela contract to spend debt tokens

Step 4: Lender posts offer to API (POST /api/orders/:id/offer)
   - Server stores offer

Step 5: Bot/relayer detects matched order+offer
   - Calls settle() on-chain with both signatures + actual asset arrays

Step 6: On-chain settle() execution
   |
   +-- 1. Check order.deadline not passed
   +-- 2. Verify asset hashes match order commitments
   +-- 3. Verify asset counts match
   +-- 4. Validate all asset rules (same as create_inscription)
   +-- 5. Verify offer.order_hash == order message hash
   +-- 6. Verify borrower SNIP-12 signature (ISRC6)
   +-- 7. Verify lender SNIP-12 signature (ISRC6)
   +-- 8. Consume borrower nonce (NoncesComponent)
   +-- 9. Consume lender nonce (NoncesComponent)
   +-- 10. Create inscription (compute ID, store, mint NFT, create TBA)
   +-- 11. Lock collateral (borrower -> TBA)
   +-- 12. Calculate shares + fee shares
   +-- 13. Mint ERC-1155 shares to lender
   +-- 14. Mint fee shares to treasury
   +-- 15. Transfer debt: lender -> borrower (net of relayer fee)
   +-- 16. Transfer fee: lender -> relayer
   +-- 17. Emit: InscriptionCreated, InscriptionSigned, OrderSettled
```

**Relayer fee calculation per debt asset:**
```
total_amount = scale_by_percentage(asset.value, actual_percentage)
fee_amount = total_amount * relayer_fee_bps / MAX_BPS   // rounds down
net_amount = total_amount - fee_amount
```

---

## 6. Signed Order Matching Engine Flow

```
Step 1: Maker creates inscription on-chain (create_inscription)

Step 2: Maker signs SignedOrder off-chain (SNIP-12)
   - References the inscription_id
   - Sets bps (total offered), min_fill_bps, deadline, nonce
   - Optionally sets allowed_taker for private OTC

Step 3: Taker calls fill_signed_order(order, signature, fill_bps)

   First fill:
   +-- 1. assert(caller != maker)                    // no self-trade
   +-- 2. assert(caller == allowed_taker || zero)     // private taker
   +-- 3. assert(timestamp <= deadline)               // not expired
   +-- 4. assert(nonce >= maker_min_nonce)            // not bulk cancelled
   +-- 5. assert(!cancelled_orders[hash])             // not individually cancelled
   +-- 6. assert(fill_bps >= min_fill_bps)            // minimum fill
   +-- 7. assert(filled + fill_bps <= bps)            // no overfill
   +-- 8. Verify SNIP-12 signature (ISRC6)
   +-- 9. Register order: signed_orders[hash] = true
   +-- 10. _fill_inscription(inscription_id, fill_bps, caller)
   +-- 11. filled_amounts[hash] += fill_bps
   +-- 12. Emit OrderFilled

   Subsequent fills (same order, different taker):
   +-- Steps 1-7: same checks
   +-- 8. SKIP signature verification (already registered)
   +-- 9. SKIP (already registered)
   +-- Steps 10-12: same

Step 4: Maker cancellation options
   - cancel_order(order): sets cancelled_orders[hash] = true
     - Only callable by maker
     - Emits OrderCancelled
   - cancel_orders_by_nonce(min_nonce): sets maker_min_nonce[caller] = min_nonce
     - min_nonce must be strictly > current
     - Invalidates all orders with nonce < min_nonce
     - Emits OrdersBulkCancelled
```

**Partial fill example:**
```
Order: bps=10000, min_fill_bps=2500
  Fill 1: Taker A fills 4000 BPS -> total_filled = 4000
  Fill 2: Taker B fills 3000 BPS -> total_filled = 7000
  Fill 3: Taker C fills 3000 BPS -> total_filled = 10000 (fully filled)
  Fill 4: Taker D fills 1000 BPS -> REVERTS (overfill)
```

---

## 7. Cancellation Flow

```
Creator                      StelaProtocol
   |                              |
   |--- cancel_inscription() ---->|
   |    (inscription_id)          |
   |                              |  1. Validate inscription exists
   |                              |  2. Validate caller is creator
   |                              |  3. Validate issued_debt_pct == 0
   |                              |     (inscription not yet signed)
   |                              |  4. Clear all asset storage maps
   |                              |  5. Zero out inscription struct
   |                              |     [InscriptionCancelled]
   |                              |
   |  NOTE: Not paused -- can     |
   |  cancel during emergency     |
```

- Only the creator (non-zero address between borrower/lender) can cancel
- Cannot cancel after any portion has been filled
- Clears all indexed asset maps + zeros the inscription struct
