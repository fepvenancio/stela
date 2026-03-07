# Stela Genesis NFT System -- Technical Specification

**Author:** Architect Agent
**Date:** 2026-03-05 (Updated)
**Status:** Design Complete — Protocol Overhaul

---

## 1. Overview

The Stela Genesis system introduces a 300-supply ERC721 NFT collection ("StelaGenesis") whose holders receive fee **discounts** on protocol operations. Fees are transferred directly to a treasury address via simple `transfer()`. There is no FeeVault contract.

**Two deliverables:**

| Contract | Purpose |
|----------|---------|
| `StelaGenesis` | ERC721 mint contract, 300 supply, 1,000 STRK mint price, 50 treasury reserve |
| `stela.cairo` (modified) | Fee constants, treasury-direct transfers, NFT-based discount calculation |

---

## 1.1 Design References

Each component draws from proven DeFi protocol patterns, adapted for Cairo and Stela's simpler requirements:

| Component | Reference Protocol | What We Took | What We Simplified |
|-----------|-------------------|-------------|-------------------|
| **NFT Mint** | Ekubo (StarkNet) | Clean distribution, no VC complexity, 100% circulating from day one, ERC20 payment | No TWAMM sale mechanism -- simple fixed-price mint |
| **Fee Model** | Uniswap V3 fee switch + volume-based tiers | NFT-gated discounts with volume tiers, treasury-direct fee routing | No FeeVault, no cumulative sum pattern -- simple discount calculation at settle/redeem time |
| **Treasury** | MakerDAO Smart Burn Engine | Treasury accumulates real ERC20 tokens (not synthetic shares) | No automated buyback/burn -- manual treasury management |

### Why These References Matter

**Uniswap V3's fee switch** inspired our backwards-compatibility toggle: `genesis_contract == zero_address` disables all discount logic, exactly like Uniswap's `feeProtocol == 0` disables protocol fees. This zero-address-means-off pattern is clean and requires no separate boolean flag.

**Volume-based tiers** draw from loyalty programs common in DeFi (e.g., exchange fee tiers). Users who settle more volume earn higher discounts, incentivizing protocol usage. Combined with NFT holding requirements, this creates a dual incentive: hold NFTs and use the protocol.

---

## 2. Fee Structure

### 2.1 Fee Constants

| Event | Total Fee (BPS) | Relayer | Treasury |
|-------|----------------|---------|----------|
| **SETTLE (loan)** | 25 | 5 (never discounted) | 20 |
| **SETTLE (swap)** | 15 | 5 (never discounted) | 10 |
| **REDEEM** | 0 | 0 | 0 |
| **LIQUIDATE** | 0 | 0 | 0 |

All fees charged at settle only. No redeem fee. No share dilution.
Fee floors after NFT discount: settle treasury min 10 BPS, swap treasury min 5 BPS.

### 2.2 NFT Discount Model

Genesis NFT holders receive fee discounts on the treasury portion (never the relayer portion):
- **Base discount**: 15% (holding 1+ NFT)
- **Volume tiers**: +5% per tier (7 tiers from $10K to $1M settled volume)
- **Per-extra-NFT bonus**: +2% per additional NFT held
- **Discount cap**: 50% maximum

Discount applies only to the treasury portion of the fee.

### 2.3 Treasury-Direct Model

Fees are transferred directly to the treasury address via `transfer()`. There is no FeeVault contract. The treasury accumulates actual ERC20 tokens.

New storage: `volume_settled` (per-address u256), `genesis_contract` (admin-set).

### 2.4 Backwards Compatibility

When `genesis_contract == zero_address` (not configured), no discount logic runs. Full fees apply. This is critical because:

1. Existing deployed contracts must not break
2. SNIP-12 signatures are NOT affected (fee extraction is internal to the contract, not part of signed data)
3. Calldata layout is NOT affected (no new parameters to settle/redeem/etc.)

---

## 3. StelaGenesis ERC721 Contract

### 3.1 File Location

```
src/genesis.cairo
```

Add to `src/lib.cairo`:
```cairo
pub mod genesis;
```

### 3.2 Dependencies

Uses OpenZeppelin Cairo components already in Scarb.toml:
- `openzeppelin_token` (ERC721Component)
- `openzeppelin_access` (OwnableComponent)
- `openzeppelin_introspection` (SRC5Component)
- `openzeppelin_security` (PausableComponent)
- `openzeppelin_interfaces` (IERC20Dispatcher for STRK/ERC20 transfers)

### 3.3 Storage

```cairo
#[storage]
struct Storage {
    // OZ components
    #[substorage(v0)]
    erc721: ERC721Component::Storage,
    #[substorage(v0)]
    ownable: OwnableComponent::Storage,
    #[substorage(v0)]
    src5: SRC5Component::Storage,
    #[substorage(v0)]
    pausable: PausableComponent::Storage,
    // Mint state
    total_minted: u256,           // current count of minted tokens
    mint_price: u256,             // price in STRK (1,000 STRK = 1_000_000_000_000_000_000_000)
    payment_token: ContractAddress, // STRK contract address (or any ERC20)
    mint_recipient: ContractAddress, // address that receives mint proceeds
    max_supply: u256,             // 300
    // Optional: mint allowlist
    mint_enabled: bool,           // global mint toggle
}
```

### 3.4 Interface

```cairo
#[starknet::interface]
pub trait IStelaGenesis<TContractState> {
    /// Mint one Genesis NFT. Caller must have approved `payment_token` for `mint_price`.
    /// Token IDs are sequential starting from 1.
    fn mint(ref self: TContractState);

    /// Batch mint multiple NFTs (max 5 per tx to limit gas).
    fn mint_batch(ref self: TContractState, quantity: u256);

    // --- Views ---
    fn total_minted(self: @TContractState) -> u256;
    fn max_supply(self: @TContractState) -> u256;
    fn mint_price(self: @TContractState) -> u256;
    fn mint_enabled(self: @TContractState) -> bool;

    // --- Admin (owner only) ---
    fn set_mint_price(ref self: TContractState, price: u256);
    fn set_mint_enabled(ref self: TContractState, enabled: bool);
    fn set_mint_recipient(ref self: TContractState, recipient: ContractAddress);
    fn set_base_uri(ref self: TContractState, base_uri: ByteArray);
    /// Owner can mint to specific address (for reserves/airdrops).
    fn admin_mint(ref self: TContractState, to: ContractAddress, quantity: u256);
}
```

### 3.5 Constructor

```cairo
#[constructor]
fn constructor(
    ref self: ContractState,
    owner: ContractAddress,
    payment_token: ContractAddress,  // STRK address on StarkNet
    mint_recipient: ContractAddress,  // treasury or multisig
    base_uri: ByteArray,
) {
    self.erc721.initializer("Stela Genesis", "SGEN", base_uri);
    self.ownable.initializer(owner);
    self.max_supply.write(300);
    self.mint_price.write(1_000_000_000_000_000_000_000); // 1,000 STRK (18 decimals)
    self.payment_token.write(payment_token);
    self.mint_recipient.write(mint_recipient);
    self.mint_enabled.write(false); // starts disabled, owner enables
    self.total_minted.write(0);
}
```

### 3.6 Mint Logic

```cairo
fn mint(ref self: ContractState) {
    self.pausable.assert_not_paused();
    assert(self.mint_enabled.read(), 'GENESIS: mint disabled');

    let minted = self.total_minted.read();
    assert(minted < self.max_supply.read(), 'GENESIS: sold out');

    let caller = get_caller_address();
    let price = self.mint_price.read();

    // Pull payment
    let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
    token.transfer_from(caller, self.mint_recipient.read(), price);

    // Mint sequential token ID (1-indexed)
    let token_id = minted + 1;
    self.erc721.mint(caller, token_id);
    self.total_minted.write(token_id);
}
```

`mint_batch` follows the same pattern in a loop with `quantity <= 5` guard.

`admin_mint` skips payment and mint_enabled check, only requires owner.

### 3.7 Key Design Decisions

**Inspired by Ekubo's launch philosophy:** clean, no VC allocation, no complex vesting. No whitelist phases, no Dutch auctions, no bonding curves. 50 NFTs auto-mint to treasury at deployment, 250 available for public mint at a fixed price of 1,000 STRK each.

- **Sequential IDs (1-300):** Simple, predictable, no randomness needed. No reveal mechanics or metadata shuffle -- this is a utility NFT for fee discounts, not a PFP collection.
- **Constructor mints 50 to treasury (IDs 1-50):** Public supply is 250 NFTs (IDs 51-300). Per-wallet cap of 5.
- **ERC20 payment (STRK token):** StarkNet STRK is an ERC20, so `transfer_from` works. No need for payable patterns. Priced at 1,000 STRK per NFT.
- **No allowlist phase initially:** Can be added later via a Merkle proof or simple mapping. The `mint_enabled` toggle is sufficient for launch control.
- **No lock-up or vesting:** Genesis NFTs are freely tradeable from mint. The fee discount utility makes them inherently valuable to hold -- no artificial lock needed.

---

## 4. Fee Discount System (replaces FeeVault)

### 4.1 Overview

Instead of a FeeVault that distributes fee revenue to NFT holders, Genesis NFTs provide fee **discounts** to their holders. Fees are transferred directly to the treasury via simple `transfer()`.

### 4.2 Discount Calculation

```
base_discount = 15%                           (holding 1+ NFT)
volume_discount = 5% * volume_tier            (7 tiers: $10K, $25K, $50K, $100K, $250K, $500K, $1M)
nft_bonus = 2% * (nft_count - 1)              (per extra NFT beyond the first)
total_discount = min(base_discount + volume_discount + nft_bonus, 50%)
```

The discount applies only to the treasury portion of fees. The relayer portion (5 BPS) is never discounted. Fee floors: settle treasury 10 BPS minimum, swap treasury 5 BPS minimum. No redeem fee.

### 4.3 Storage

```cairo
// In StelaProtocol storage:
genesis_contract: ContractAddress,            // Genesis NFT for discount checks (zero = disabled)
volume_settled: Map<ContractAddress, u256>,    // per-address cumulative settled volume
```

### 4.4 Admin Functions

```cairo
fn set_genesis_contract(ref self: ContractState, genesis: ContractAddress);
fn get_genesis_contract(self: @ContractState) -> ContractAddress;
fn get_volume_settled(self: @ContractState, address: ContractAddress) -> u256;
```

---

## 5. stela.cairo Modifications

### 5.1 Guiding Principle

All changes are **additive**. No existing storage slots are moved. No existing function signatures change. No SNIP-12 structs change. The discount behavior activates only when `genesis_contract != zero_address`.

### 5.2 New Storage Variables

```cairo
// Genesis NFT discount system
genesis_contract: ContractAddress,            // zero address = discounts disabled
volume_settled: Map<ContractAddress, u256>,    // per-address cumulative settled volume
```

Constants at module level:

```cairo
// Fee constants (in BPS) — all fees at settle only, no redeem fee, no share dilution
const RELAYER_BPS: u256 = 5;               // Relayer portion (never discounted)
const SETTLE_TREASURY_BASE: u256 = 20;     // Treasury base on settle (lending)
const SWAP_TREASURY_BASE: u256 = 10;       // Treasury base on swap (duration=0)
const SETTLE_TREASURY_FLOOR: u256 = 10;    // Min treasury on settle after discount
const SWAP_TREASURY_FLOOR: u256 = 5;       // Min treasury on swap after discount
```

### 5.3 New Admin Functions

```cairo
fn set_treasury(ref self: TContractState, treasury: ContractAddress);
fn get_treasury(self: @TContractState) -> ContractAddress;
fn set_genesis_contract(ref self: TContractState, genesis: ContractAddress);
fn get_genesis_contract(self: @TContractState) -> ContractAddress;
fn get_volume_settled(self: @TContractState, address: ContractAddress) -> u256;
```

### 5.4 Fee Routing

Treasury receives fees via simple `transfer()`. No FeeVault, no deposit pattern, no approval management needed.

### 5.5 Summary of Changed Functions

| Function | Change Type | Description |
|----------|------------|-------------|
| `settle()` | Modified logic | Loans 25 BPS (5 relayer + 20 treasury), swaps 15 BPS (5 relayer + 10 treasury), discount for NFT holders |
| `redeem()` | Modified logic | No fee — lenders get 100% of assets |
| `set_treasury()` | Existing | Sets treasury address (replaces set_fee_vault) |
| `get_treasury()` | Existing | Gets treasury address (replaces get_fee_vault) |
| `set_genesis_contract()` | New function | Admin setter for Genesis NFT address |
| `get_genesis_contract()` | New function | View for Genesis NFT address |
| `get_volume_settled()` | New function | View for per-address settled volume |

### 5.6 What Does NOT Change

- `create_inscription()` -- no fees
- `cancel_inscription()` -- no fees
- `sign_inscription()` / `_fill_inscription()` -- no fees
- `repay()` / `_pull_repayment()` -- no fees (borrower pays back exactly what they owe)
- `liquidate()` / `_pull_collateral_from_locker()` -- no fees
- `fill_signed_order()` -- no fees (uses `_fill_inscription` internally)
- `cancel_order()` / `cancel_orders_by_nonce()` -- no fees
- All SNIP-12 structs (`InscriptionOrder`, `LendOffer`, `SignedOrder`) -- **unchanged**
- All calldata layouts -- **unchanged**
- Constructor signature -- **unchanged**

---

## 6. Deployment Sequence

1. **Deploy StelaGenesis** ERC721 contract with owner, STRK token address, mint recipient, treasury, and base URI — 50 NFTs auto-mint to treasury
2. **Call `stela.set_treasury(treasury_address)`** to set fee recipient
3. **Call `stela.set_genesis_contract(genesis_address)`** to activate NFT-based fee discounts
4. **Enable minting** via `genesis.set_mint_enabled(true)`

Step 1 is independent. Steps 2-3 require the Stela contract to be deployed. Step 4 can happen any time after step 1.

---

## 7. File Structure Summary

### New Files

```
src/genesis.cairo              -- StelaGenesis ERC721 contract
src/interfaces/igenesis.cairo   -- IStelaGenesis interface
```

### Modified Files

```
src/lib.cairo                  -- Add genesis module
src/interfaces.cairo           -- Add igenesis module
src/stela.cairo                -- Add storage (genesis_contract, volume_settled), discount logic, admin functions
src/interfaces/istela.cairo    -- Add set_genesis_contract/get_genesis_contract/get_volume_settled to trait
```

---

## 8. Testing Strategy

### 8.1 StelaGenesis Tests

- Mint single: verify token minted, payment transferred, total_minted incremented
- Mint batch: verify all tokens minted sequentially
- Sold out: verify revert after 300 mints
- Treasury reserve: verify 50 NFTs auto-minted to treasury in constructor
- Per-wallet cap: verify max 5 per wallet
- Price enforcement: verify exact payment required
- Admin mint: verify owner bypass of payment/toggle
- Mint disabled: verify revert when toggle is off
- Transfers: verify standard ERC721 transfer/approve behavior

### 8.2 Fee Discount Tests

- settle() with Genesis NFT: verify discounted treasury fee (15% base discount)
- settle() without Genesis NFT: verify full 20 BPS fee
- settle() with volume tiers: verify increasing discounts
- settle() fee floor: verify minimum 10 BPS
- redeem() is fee-free: verify no treasury transfer on redeem
- Multiple NFTs: verify per-NFT bonus (+2% each)
- Discount cap: verify 50% maximum
- Volume tracking: verify volume_settled increments on settle

### 8.3 Integration Tests

- Full lifecycle with Genesis: create -> settle -> repay -> redeem, verify fees at settle only
- Swap with Genesis fee: settle(duration=0) -> redeem, verify fees at settle only
- Multi-lender with Genesis fee: multiple settles, verify fees proportional
- Volume accumulation: verify volume_settled across multiple operations

---

## 9. Security Considerations

1. **Integer overflow:** All fee calculations are bounded by MAX_BPS (10,000). With u256 math, overflow is impossible for any realistic token amount.

2. **Discount manipulation:** Discounts are checked at settle/redeem time against on-chain NFT balance and volume. No caching means discounts always reflect current state.

3. **Fee floors:** Minimum fees (settle treasury 10 BPS, swap treasury 5 BPS) prevent discounts from reducing fees to near-zero.

4. **Volume tracking:** `volume_settled` is per-address and cumulative. Cannot be reset or manipulated.

---

## 10. Gas Considerations

1. **Treasury transfer per settle:** Each debt asset in a settle requires 1 extra `transfer` to the treasury (vs the old model). No FeeVault approval/deposit overhead.

2. **Discount check:** Reading NFT balance and volume_settled adds 2 storage reads per settle/redeem when genesis_contract is configured. Negligible gas impact.

3. **No redeem fee:** Lenders receive 100% of assets at redemption. All protocol revenue is collected at settle time.
