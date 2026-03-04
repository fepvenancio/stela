# Stela Genesis NFT System -- Technical Specification

**Author:** Architect Agent
**Date:** 2026-03-03
**Status:** Design Complete

---

## 1. Overview

The Stela Genesis system introduces a 500-supply ERC721 NFT collection ("StelaGenesis") whose holders earn a share of protocol fees. Fees are deposited into a "FeeVault" contract and can be claimed by NFT holders at any time, across multiple ERC20 tokens.

**Three deliverables:**

| Contract | Purpose |
|----------|---------|
| `StelaGenesis` | ERC721 mint contract, 500 supply, 5,000 STRK mint price |
| `FeeVault` | Multi-token fee accumulator with per-NFT claim tracking |
| `stela.cairo` (modified) | Fee splitting at settle/redeem to route fees to vault + treasury |

---

## 1.1 Design References

Each component draws from proven DeFi protocol patterns, adapted for Cairo and Stela's simpler requirements:

| Component | Reference Protocol | What We Took | What We Simplified |
|-----------|-------------------|-------------|-------------------|
| **NFT Mint** | Ekubo (StarkNet) | Clean distribution, no VC complexity, 100% circulating from day one, ERC20 payment | No TWAMM sale mechanism -- simple fixed-price mint |
| **FeeVault** | GMX RewardTracker + Synthetix StakingRewards | Cumulative reward-per-token pattern with checkpoint-on-claim delta math | No staking/unstaking (fixed 500 NFTs), no time-weighted rates, no reward periods |
| **Fee Routing** | Camelot DEX (22.5% to xGRAIL) + Uniswap V3 fee switch | Multi-destination fee split with toggle (zero address = off, like Uni's fee switch) | No governance voting to toggle -- owner-controlled via `set_fee_vault()` |
| **Treasury** | MakerDAO Smart Burn Engine | Treasury accumulates real ERC20 tokens (not synthetic shares) | No automated buyback/burn -- manual treasury management |

### Why These References Matter

**GMX's `cumulativeRewardPerToken` pattern** (from RewardTracker.sol) is exactly what our FeeVault implements. GMX tracks: `cumulativeRewardPerToken += (blockReward * PRECISION) / supply`, then per-user: `reward = stakedAmount * (cumulative - previousCumulative) / PRECISION`. Our version is simpler because `stakedAmount` is always 1 (each NFT has equal weight) and `supply` is always 500 (no deposits/withdrawals), so we drop the PRECISION multiplier and the staking math entirely.

**Synthetix's `rewardPerTokenStored` + `userRewardPerTokenPaid`** uses the same delta-checkpoint approach but adds time-weighted distribution (`rewardRate * elapsed / totalSupply`). We don't need time-weighting since our deposits are discrete events (each settle/redeem), not continuous streams.

**MasterChef vs Synthetix:** Per RareSkills analysis, MasterChef is more gas-efficient because it transfers rewards on every interaction rather than accumulating in a mapping. Our FeeVault uses the Synthetix-style explicit `claim()` instead, because we want NFT holders to claim on their own schedule, not force claims on every fee deposit (which would be impossible with 500 NFTs).

**Uniswap V3's fee switch** inspired our backwards-compatibility toggle: `fee_vault == zero_address` disables all new fee logic, exactly like Uniswap's `feeProtocol == 0` disables protocol fees. This zero-address-means-off pattern is clean and requires no separate boolean flag.

**Camelot's multi-destination routing** (60% LPs, 22.5% xGRAIL, 12.5% buyback, 5% ops) validates our 2-way split approach. Their V2 sends 22.5% to xGRAIL stakers -- we send 20 BPS (settle) / 10 BPS (redeem) to Genesis holders. The principle is the same: route protocol revenue directly to token/NFT holders in real yield (actual ERC20 tokens, not inflationary emissions).

---

## 2. Fee Structure

### 2.1 Current State

Currently, stela.cairo applies a single `inscription_fee` (default 10 BPS) on sign/settle. This fee is minted as ERC1155 shares to the treasury address. There is no ERC20 fee extraction; the treasury just accumulates ERC1155 shares and redeems them later.

The `relayer_fee` (10 BPS) is deducted from debt transfers during `settle()` only and paid to the caller (relayer bot).

### 2.2 New Fee Model

All fee extraction happens in **ERC20 tokens**, not ERC1155 shares. The existing `inscription_fee` (share-based) mechanism is preserved for backwards compatibility but is now understood as a separate "dilution fee" concept. The new Genesis fees are **additive** and extracted from actual token flows.

| Event | Total Fee (BPS) | Relayer | Genesis Vault | Treasury |
|-------|----------------|---------|---------------|----------|
| **SETTLE** | 25 | 5 | 15 | 5 |
| **REDEEM** | 10 | 0 | 7 | 3 |
| **LIQUIDATE** | 0 | 0 | 0 | 0 |

**Implementation approach:** Fees are taken as a percentage of the ERC20 token amounts flowing through each operation. For settle, the fee is deducted from the debt transfer (lender -> borrower). For redeem, the fee is deducted from the payout (contract -> redeemer).

### 2.3 Backwards Compatibility

When `fee_vault == zero_address` (not configured), all new fee logic is **skipped entirely**. The contract behaves exactly as it does today. This is critical because:

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
    mint_price: u256,             // price in STRK (5,000 STRK = 5_000_000_000_000_000_000_000)
    payment_token: ContractAddress, // STRK contract address (or any ERC20)
    mint_recipient: ContractAddress, // address that receives mint proceeds
    max_supply: u256,             // 500
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
    self.max_supply.write(500);
    self.mint_price.write(5_000_000_000_000_000_000_000); // 5,000 STRK (18 decimals)
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

**Inspired by Ekubo's launch philosophy:** clean, no VC allocation, no complex vesting. 100% of supply available to mint at a fixed price. No whitelist phases, no Dutch auctions, no bonding curves. The mint is a one-time event that creates 500 equal stakeholders in the protocol's fee revenue.

- **Sequential IDs (1-500):** Simple, predictable, no randomness needed. No reveal mechanics or metadata shuffle -- this is a utility NFT for fee claims, not a PFP collection.
- **ERC20 payment (STRK token):** StarkNet STRK is an ERC20, so `transfer_from` works. No need for payable patterns. Same pattern Ekubo used for their TWAMM token sale. Priced at 5,000 STRK per NFT (~$210 at $0.042/STRK), total raise: 1,500,000 STRK (~$63K).
- **No allowlist phase initially:** Can be added later via a Merkle proof or simple mapping. The `mint_enabled` toggle is sufficient for launch control. Keeping it simple for a solo founder project.
- **FeeVault does NOT depend on StelaGenesis:** The vault only needs to know `max_supply` (hardcoded to 500) and calls `erc721.owner_of(token_id)` to verify ownership at claim time. This means the NFT contract is a standard ERC721 with no special hooks into the vault. Clean separation of concerns.
- **No lock-up or vesting:** Unlike Ekubo's team allocation with a no-sell commitment, Genesis NFTs are freely tradeable from mint. The "real yield" from fee claims makes them inherently valuable to hold -- no artificial lock needed.

---

## 4. FeeVault Contract

### 4.1 File Location

```
src/fee_vault.cairo
```

Add to `src/lib.cairo`:
```cairo
pub mod fee_vault;
```

### 4.2 Core Math: Cumulative Sum Model

The FeeVault uses the **cumulative reward-per-token** pattern -- the same algorithm powering GMX's RewardTracker and Synthetix's StakingRewards, which together secure billions in staked assets. Our version is a degenerate (simpler) case because all 500 NFTs have equal weight and the total count never changes.

**GMX RewardTracker equivalent mapping:**

| GMX RewardTracker | Stela FeeVault | Simplification |
|-------------------|----------------|----------------|
| `cumulativeRewardPerToken` | `cumulative_per_nft[token]` | Per-token (multi-ERC20) |
| `previousCumulatedRewardPerToken[user]` | `claimed_per_nft[token][token_id]` | Per-NFT instead of per-user |
| `stakedAmounts[user]` | (always 1) | Fixed, not stored |
| `totalSupply` | `total_nfts` (500) | Fixed, not stored per-token |
| `PRECISION` multiplier | (not needed) | Integer division with dust accumulator instead |

**The math for each ERC20 fee token:**

```
// On deposit (GMX: _updateRewards, Synthetix: notifyRewardAmount)
cumulative_per_nft[token] += deposit_amount / TOTAL_NFTS
```

**Per-NFT checkpoint (GMX: previousCumulatedRewardPerToken, Synthetix: userRewardPerTokenPaid):**

```
claimed_per_nft[token][token_id] = cumulative_per_nft[token]   // set at last claim
```

**Claimable calculation (GMX: claimable, Synthetix: earned):**

```
claimable = cumulative_per_nft[token] - claimed_per_nft[token][token_id]
```

GMX uses `PRECISION = 1e30` to avoid rounding loss in their division. We avoid this complexity with a **dust accumulator** -- remainders from `deposit_amount % 500` are stored and rolled into the next deposit. Maximum dust per token: 499 wei. This is simpler than a precision multiplier and produces exact results.

**Why this works for multi-token:** Each ERC20 has its own independent cumulative counter, like having a separate GMX RewardTracker per token. A single `deposit()` call updates one token's counter. A single `claim()` call can sweep all tokens for one NFT.

### 4.3 Storage

```cairo
#[storage]
struct Storage {
    #[substorage(v0)]
    ownable: OwnableComponent::Storage,
    // The Genesis NFT contract (for ownership checks)
    genesis_nft: ContractAddress,
    // Total NFT supply (fixed at 500, stored for flexibility)
    total_nfts: u256,
    // List of registered fee tokens (for enumeration during claim_all)
    fee_tokens: Map<u32, ContractAddress>,  // index -> token address
    fee_token_count: u32,
    is_fee_token: Map<ContractAddress, bool>,  // for O(1) lookup
    // Cumulative fee per NFT for each token
    // cumulative_per_nft[token_address] = total accumulated per single NFT
    cumulative_per_nft: Map<ContractAddress, u256>,
    // Last claimed cumulative value per NFT per token
    // claimed_per_nft[token_address][token_id] = cumulative value at last claim
    claimed_per_nft: Map<(ContractAddress, u256), u256>,
    // Dust accumulator: remainder from integer division (deposit_amount % TOTAL_NFTS)
    // Accumulated per token until it reaches enough to distribute
    dust: Map<ContractAddress, u256>,
}
```

### 4.4 Interface

```cairo
#[starknet::interface]
pub trait IFeeVault<TContractState> {
    /// Deposit fees into the vault for distribution to NFT holders.
    /// Callable by anyone (the Stela contract calls this during settle/redeem).
    /// The caller must have approved `token` for `amount` before calling.
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);

    /// Claim accumulated fees for a specific NFT across all registered tokens.
    /// Caller must be the current owner of the NFT (checked via genesis_nft.owner_of).
    fn claim(ref self: TContractState, token_id: u256);

    /// Claim accumulated fees for a specific NFT for a specific token only.
    fn claim_token(ref self: TContractState, token_id: u256, token: ContractAddress);

    /// Claim fees for multiple NFTs at once (for holders with multiple NFTs).
    fn claim_batch(ref self: TContractState, token_ids: Array<u256>);

    // --- Views ---

    /// Get the claimable amount for a specific NFT and token.
    fn claimable(self: @TContractState, token_id: u256, token: ContractAddress) -> u256;

    /// Get claimable amounts for a specific NFT across all registered tokens.
    /// Returns parallel arrays of (token_addresses, amounts).
    fn claimable_all(self: @TContractState, token_id: u256) -> (Array<ContractAddress>, Array<u256>);

    /// Get the total cumulative fees deposited per NFT for a token.
    fn cumulative_per_nft(self: @TContractState, token: ContractAddress) -> u256;

    /// Get all registered fee tokens.
    fn get_fee_tokens(self: @TContractState) -> Array<ContractAddress>;

    /// Get the Genesis NFT contract address.
    fn get_genesis_nft(self: @TContractState) -> ContractAddress;

    // --- Admin ---

    /// Register a new fee token. Only owner.
    /// Tokens are auto-registered on first deposit, but this allows pre-registration.
    fn register_token(ref self: TContractState, token: ContractAddress);

    /// Update the Genesis NFT contract address. Only owner.
    fn set_genesis_nft(ref self: TContractState, genesis_nft: ContractAddress);
}
```

### 4.5 Constructor

```cairo
#[constructor]
fn constructor(
    ref self: ContractState,
    owner: ContractAddress,
    genesis_nft: ContractAddress,
    total_nfts: u256,
) {
    self.ownable.initializer(owner);
    assert(!genesis_nft.is_zero(), 'VAULT: invalid address');
    assert(total_nfts > 0, 'VAULT: zero nfts');
    self.genesis_nft.write(genesis_nft);
    self.total_nfts.write(total_nfts);
    self.fee_token_count.write(0);
}
```

### 4.6 Deposit Logic

```cairo
fn deposit(ref self: ContractState, token: ContractAddress, amount: u256) {
    assert(amount > 0, 'VAULT: zero amount');

    let total_nfts = self.total_nfts.read();

    // Auto-register token if not already registered
    if !self.is_fee_token.read(token) {
        self._register_token(token);
    }

    // Pull tokens from caller
    let erc20 = IERC20Dispatcher { contract_address: token };
    erc20.transfer_from(get_caller_address(), get_contract_address(), amount);

    // Add any accumulated dust from previous deposits
    let prev_dust = self.dust.read(token);
    let total = amount + prev_dust;

    // Calculate per-NFT share and new dust
    let per_nft = total / total_nfts;
    let new_dust = total % total_nfts;

    // Update cumulative counter
    if per_nft > 0 {
        let current = self.cumulative_per_nft.read(token);
        self.cumulative_per_nft.write(token, current + per_nft);
    }

    // Store remaining dust
    self.dust.write(token, new_dust);

    // Emit Deposited event
}
```

### 4.7 Claim Logic

```cairo
fn claim(ref self: ContractState, token_id: u256) {
    // Verify caller owns this NFT
    let nft = IERC721Dispatcher { contract_address: self.genesis_nft.read() };
    let owner = nft.owner_of(token_id);
    assert(get_caller_address() == owner, 'VAULT: not owner');

    // Iterate all registered tokens and claim each
    let count = self.fee_token_count.read();
    let mut i: u32 = 0;
    while i < count {
        let token = self.fee_tokens.read(i);
        self._claim_single(token_id, token, owner);
        i += 1;
    };
}

fn _claim_single(
    ref self: ContractState,
    token_id: u256,
    token: ContractAddress,
    recipient: ContractAddress,
) {
    let cumulative = self.cumulative_per_nft.read(token);
    let claimed = self.claimed_per_nft.read((token, token_id));
    let claimable = cumulative - claimed;

    if claimable > 0 {
        // Update claimed checkpoint
        self.claimed_per_nft.write((token, token_id), cumulative);

        // Transfer tokens to NFT owner
        let erc20 = IERC20Dispatcher { contract_address: token };
        erc20.transfer(recipient, claimable);

        // Emit Claimed event
    }
}
```

### 4.8 Key Design Decisions

- **No staking required (differs from GMX/BendDAO):** GMX requires staking GMX tokens to earn fees; BendDAO requires locking BEND into veBEND. We skip this entirely. NFT holders do not need to lock/stake their NFTs. Ownership is checked at claim time via `owner_of()`. If someone sells their NFT, the new owner gets all unclaimed rewards. This is intentional -- it makes the NFT more valuable since rewards travel with it. For a 500-supply NFT, the gas overhead of per-NFT checkpoints is negligible.
- **Real yield, not emissions (like GMX ETH/AVAX rewards):** GMX distributes 30% of protocol fees in ETH/AVAX to stakers -- actual tokens, not inflationary emissions. Our vault does the same: Genesis holders earn real ERC20 tokens from actual protocol activity. No token inflation, no dilution. This is the "real yield" model that BendDAO (100% lending revenue to stakers) and Camelot (22.5% to xGRAIL) also follow.
- **Dust handling:** When `deposit_amount < 500`, integer division gives 0 per NFT. Dust is accumulated across deposits and distributed once it reaches a distributable amount. This replaces GMX's PRECISION multiplier approach with something simpler. Maximum dust: 499 wei per token.
- **Auto-registration:** Fee tokens are automatically registered on first deposit. No admin action needed when Stela starts using a new ERC20 as debt. Similar to how Uniswap V3's protocol fee accumulates per-pool without pre-registration.
- **Gas-efficient claim:** `claim_batch` lets holders with multiple NFTs claim in one tx. `claim_token` lets them claim a single token if gas is a concern.
- **Checks-effects-interactions on claim:** The cumulative checkpoint is updated BEFORE the transfer, following the same pattern as Synthetix's `getReward()` which zeroes `rewards[account]` before calling `safeTransfer`.

### 4.9 Events

```cairo
#[derive(Drop, starknet::Event)]
pub struct Deposited {
    #[key]
    pub token: ContractAddress,
    pub amount: u256,
    pub per_nft: u256,
}

#[derive(Drop, starknet::Event)]
pub struct Claimed {
    #[key]
    pub token_id: u256,
    #[key]
    pub token: ContractAddress,
    pub amount: u256,
    pub recipient: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct TokenRegistered {
    #[key]
    pub token: ContractAddress,
    pub index: u32,
}
```

---

## 5. stela.cairo Modifications

### 5.1 Guiding Principle

**Inspired by Uniswap V3's fee switch:** All changes are **additive**. No existing storage slots are moved. No existing function signatures change. No SNIP-12 structs change. The new behavior activates only when `fee_vault != zero_address`, exactly like Uniswap's `feeProtocol` field -- when zero, no protocol fees are collected. When non-zero, fees are routed to the designated recipient.

**Inspired by Camelot's multi-destination routing:** Camelot splits V2 fees across 4 destinations (60% LPs, 22.5% xGRAIL, 12.5% buyback, 5% ops). Our settle fee splits across 3 destinations (borrower net, relayer, vault+treasury). The routing happens inline during the token transfer, not as a separate post-hoc distribution step.

### 5.2 New Storage Variables

Add to the `Storage` struct (after `privacy_pool`):

```cairo
// Genesis fee vault (zero address = disabled, like Uniswap's feeProtocol = 0)
fee_vault: ContractAddress,
```

**One storage variable. That's it.** Fee BPS splits are module-level constants. This follows the "don't over-engineer" principle -- for a solo founder project, hardcoded splits with redeployment-to-change is better than 7 extra storage slots with admin setters. MakerDAO's Burn Engine has configurable parameters because they have a DAO governance process; we don't need that complexity.

Constants at module level:

```cairo
// Genesis fee split constants (in BPS)
// Settle total: 25 BPS (0.25%) -- comparable to Camelot V2's ~40% non-LP share
const SETTLE_FEE_BPS: u256 = 25;       // Total fee on settle
const SETTLE_RELAYER_BPS: u256 = 5;     // Relayer portion (bot compensation)
const SETTLE_VAULT_BPS: u256 = 15;      // Genesis vault portion (60% of fee)
const SETTLE_TREASURY_BPS: u256 = 5;    // Treasury portion (20% of fee)
// Redeem total: 10 BPS (0.1%) -- light touch on exits
const REDEEM_FEE_BPS: u256 = 10;        // Total fee on redeem
const REDEEM_VAULT_BPS: u256 = 7;       // Genesis vault portion (70% of fee)
const REDEEM_TREASURY_BPS: u256 = 3;    // Treasury portion (30% of fee)
```

### 5.3 New Interface for FeeVault Dispatch

Add a new interface file:

```
src/interfaces/ifee_vault.cairo
```

```cairo
use starknet::ContractAddress;

#[starknet::interface]
pub trait IFeeVault<TContractState> {
    fn deposit(ref self: TContractState, token: ContractAddress, amount: u256);
}
```

Register in `src/interfaces.cairo`:
```cairo
pub mod ifee_vault;
```

### 5.4 New Admin Functions

Add to `IStelaProtocol` trait and impl:

```cairo
/// Set the Genesis fee vault address. Zero address disables Genesis fee splitting.
/// Only owner.
fn set_fee_vault(ref self: TContractState, fee_vault: ContractAddress);

/// Get the Genesis fee vault address.
fn get_fee_vault(self: @TContractState) -> ContractAddress;
```

Implementation:

```cairo
fn set_fee_vault(ref self: ContractState, fee_vault: ContractAddress) {
    self.ownable.assert_only_owner();
    self.fee_vault.write(fee_vault);
}

fn get_fee_vault(self: @ContractState) -> ContractAddress {
    self.fee_vault.read()
}
```

### 5.5 New Error Constants

Add to `errors.cairo`:

```cairo
pub const FEE_VAULT_NOT_SET: felt252 = 'STELA: fee vault not set';
```

(Not strictly needed since we check `is_zero()` and skip, rather than assert.)

### 5.6 Modified Functions

#### 5.6.1 `settle()` -- Fee Split on Debt Transfer

**Current behavior:** `_issue_debt_with_fee()` deducts `relayer_fee` from debt and sends it to the relayer. The rest goes to the borrower.

**New behavior:** When `fee_vault != zero_address`, the total fee is `SETTLE_FEE_BPS` (25 BPS) instead of just `relayer_fee`. The fee is split two ways:

```
relayer_amount   = (debt_amount * SETTLE_RELAYER_BPS) / MAX_BPS   // 5 BPS
vault_amount     = (debt_amount * SETTLE_VAULT_BPS) / MAX_BPS     // 20 BPS
total_fee_amount = relayer_amount + vault_amount
```

The borrower receives: `debt_amount - total_fee_amount`

**Changes to `_issue_debt_with_fee()`:**

Replace the current fee calculation with a vault-aware branch:

```cairo
fn _issue_debt_with_genesis_fee(
    ref self: ContractState,
    from: ContractAddress,        // lender
    to: ContractAddress,          // borrower
    relayer: ContractAddress,     // caller / relayer bot
    inscription_id: u256,
    debt_count: u32,
    percentage: u256,
) -> u256 {
    let vault_addr = self.fee_vault.read();
    let has_vault = !vault_addr.is_zero();
    let relayer_fee_bps = self.relayer_fee.read();

    let mut total_relayer_fee: u256 = 0;
    let mut i: u32 = 0;
    while i < debt_count {
        let asset = self.inscription_debt_assets.read((inscription_id, i));
        let total_amount = scale_by_percentage(asset.value, percentage);

        let erc20 = IERC20Dispatcher { contract_address: asset.asset };

        if has_vault {
            // Genesis fee model: 25 BPS total, split 2 ways (relayer + vault)
            let relayer_amount = (total_amount * SETTLE_RELAYER_BPS) / MAX_BPS;
            let vault_amount = (total_amount * SETTLE_VAULT_BPS) / MAX_BPS;
            let total_fee = relayer_amount + vault_amount;
            let net_amount = total_amount - total_fee;

            // 1. Net to borrower (lender -> borrower)
            if net_amount > 0 {
                erc20.transfer_from(from, to, net_amount);
            }
            // 2. Relayer fee (lender -> relayer)
            if relayer_amount > 0 {
                erc20.transfer_from(from, relayer, relayer_amount);
                total_relayer_fee += relayer_amount;
            }
            // 3. Vault fee (lender -> this contract -> FeeVault)
            if vault_amount > 0 {
                erc20.transfer_from(from, get_contract_address(), vault_amount);
                erc20.approve(vault_addr, vault_amount);
                let vault = IFeeVaultDispatcher { contract_address: vault_addr };
                vault.deposit(asset.asset, vault_amount);
            }
        } else {
            // Legacy behavior: only relayer fee
            let fee_amount = if relayer_fee_bps > 0 {
                (total_amount * relayer_fee_bps) / MAX_BPS
            } else {
                0
            };
            let net_amount = total_amount - fee_amount;

            if net_amount > 0 {
                erc20.transfer_from(from, to, net_amount);
            }
            if fee_amount > 0 {
                erc20.transfer_from(from, relayer, fee_amount);
                total_relayer_fee += fee_amount;
            }
        }

        i += 1;
    };
    total_relayer_fee
}
```

**Integration:** Modify `_issue_debt_with_fee()` in place. The vault check branches inside the existing function body -- no new entry points needed, call sites remain unchanged. The `relayer_fee_bps` parameter is still read from storage in the legacy branch.

#### 5.6.2 `redeem()` -- Fee on Payout

**Current behavior:** `_redeem_debt_assets()`, `_redeem_interest_assets()`, and `_redeem_collateral_assets()` transfer the full pro-rata amount to the redeemer.

**New behavior:** When `fee_vault != zero_address`, deduct `REDEEM_FEE_BPS` (10 BPS) from each transfer, routed entirely to the vault.

**New internal function:**

```cairo
fn _apply_redeem_fee(
    ref self: ContractState,
    asset_address: ContractAddress,
    gross_amount: u256,
) -> u256 {
    let vault_addr = self.fee_vault.read();
    if vault_addr.is_zero() || gross_amount == 0 {
        return gross_amount; // No fee, return full amount
    }

    let vault_amount = (gross_amount * REDEEM_VAULT_BPS) / MAX_BPS;
    let net_amount = gross_amount - vault_amount;

    // Deposit fee via IFeeVault.deposit()
    if vault_amount > 0 {
        let erc20 = IERC20Dispatcher { contract_address: asset_address };
        erc20.approve(vault_addr, vault_amount);
        let vault = IFeeVaultDispatcher { contract_address: vault_addr };
        vault.deposit(asset_address, vault_amount);
    }

    net_amount
}
```

**Modifications to `_redeem_debt_assets()`** (and similarly for `_redeem_interest_assets`):

```cairo
// Current code (simplified):
let amount = tracked_balance * shares / total_supply;
if amount > 0 {
    self.inscription_debt_balance.write((inscription_id, i), tracked_balance - amount);
    let erc20 = IERC20Dispatcher { contract_address: asset.asset };
    erc20.transfer(to, amount);
}

// New code:
let amount = tracked_balance * shares / total_supply;
if amount > 0 {
    self.inscription_debt_balance.write((inscription_id, i), tracked_balance - amount);
    let net_amount = self._apply_redeem_fee(asset.asset, amount);
    if net_amount > 0 {
        let erc20 = IERC20Dispatcher { contract_address: asset.asset };
        erc20.transfer(to, net_amount);
    }
}
```

**Modifications to `_redeem_collateral_assets()`:**

Same pattern for fungible assets (ERC20/ERC4626/ERC1155). For ERC721, no fee is applied (NFTs are not fungible and can't be partially charged).

**Decision: Redeem fee applies only to ERC20/ERC4626 assets.** ERC721 and ERC1155 are skipped. NFTs are indivisible and can't be split for fee extraction (same reason they can't be debt/interest). ERC1155 collateral could theoretically have a fee deducted from the amount, but routing ERC1155 tokens to the vault (which expects ERC20 deposits) adds complexity for a rare edge case.

#### 5.6.3 `_issue_debt_from_pool()` -- Private Settlement Fees

The same Genesis fee split applies to private settlements. Modify `_issue_debt_from_pool()` to follow the same pattern as `_issue_debt_with_fee()`:

When `fee_vault != zero_address`:
- Pull `total_amount` from pool to `this_contract` (single transfer)
- Split: net to borrower, relayer fee to relayer, vault fee to vault via deposit, treasury fee to treasury

When `fee_vault == zero_address`:
- Legacy behavior (relayer fee only)

#### 5.6.4 `private_redeem()` -- Same as `redeem()`

Private redeem uses the same `_redeem_debt_assets()` / `_redeem_collateral_assets()` functions, so it automatically gets the fee deduction.

#### 5.6.5 `_fill_inscription()` / `sign_inscription()` -- No Change

The on-chain sign path (`sign_inscription` -> `_fill_inscription`) currently uses `_issue_debt()` (no fee version). We could add a fee here too, but the spec says fees are only on SETTLE and REDEEM. The on-chain sign path has no relayer, so there is no relayer fee.

**Decision: No Genesis fee on `sign_inscription`/`_fill_inscription`.** Only settle (off-chain path) and redeem are fee-bearing. This is consistent with the spec.

**Rationale:** On-chain signing is already more expensive (user pays gas). Adding a fee would discourage it relative to the off-chain path for no clear benefit.

#### 5.6.6 `liquidate()` -- No Change

Per spec: "LIQUIDATE: no extra fee." No modifications needed.

### 5.7 Approval Management

The Stela contract needs to approve the FeeVault to pull tokens via `deposit()`. The approval happens inline before each `vault.deposit()` call:

```cairo
erc20.approve(vault_addr, vault_amount);
vault.deposit(asset_address, vault_amount);
```

This is safe because:
1. The approval is for the exact amount needed
2. `deposit()` calls `transfer_from(caller, this, amount)` which consumes the approval
3. No leftover approval remains

### 5.8 Summary of Changed Functions

| Function | Change Type | Description |
|----------|------------|-------------|
| `settle()` | Modified call | Calls updated `_issue_debt_with_fee()` |
| `_issue_debt_with_fee()` | Modified logic | Genesis fee split when vault is set |
| `_issue_debt_from_pool()` | Modified logic | Genesis fee split for private settlements |
| `_redeem_debt_assets()` | Modified logic | Applies redeem fee via `_apply_redeem_fee()` |
| `_redeem_interest_assets()` | Modified logic | Applies redeem fee via `_apply_redeem_fee()` |
| `_redeem_collateral_assets()` | Modified logic | Applies redeem fee for ERC20/ERC4626 only |
| `set_fee_vault()` | New function | Admin setter for vault address |
| `get_fee_vault()` | New function | View function for vault address |
| `_apply_redeem_fee()` | New function | Internal fee calculation and distribution |

### 5.9 What Does NOT Change

- `create_inscription()` -- no fees
- `cancel_inscription()` -- no fees
- `sign_inscription()` / `_fill_inscription()` -- no fees
- `repay()` / `_pull_repayment()` -- no fees (borrower pays back exactly what they owe)
- `liquidate()` / `_pull_collateral_from_locker()` -- no fees
- `fill_signed_order()` -- no fees (uses `_fill_inscription` internally)
- `cancel_order()` / `cancel_orders_by_nonce()` -- no fees
- `private_redeem()` -- inherits fee from `_redeem_*` functions (no direct change)
- All SNIP-12 structs (`InscriptionOrder`, `LendOffer`, `SignedOrder`) -- **unchanged**
- All calldata layouts -- **unchanged**
- Constructor signature -- **unchanged** (vault set post-deploy via `set_fee_vault`)

---

## 6. Deployment Sequence

1. **Deploy StelaGenesis** ERC721 contract with owner, STRK token address, mint recipient, and base URI
2. **Deploy FeeVault** with owner, StelaGenesis address, and total_nfts=500
3. **Call `stela.set_fee_vault(vault_address)`** to activate Genesis fee splitting on the existing Stela contract
4. **Enable minting** via `genesis.set_mint_enabled(true)`

Steps 1-2 are independent and can be done in parallel. Step 3 requires both to be deployed. Step 4 can happen any time after step 1.

**Note:** Since the Stela contract is upgraded by redeployment (new contract address), the new Stela contract with Genesis fee support needs to be deployed, and the frontend/bot/SDK updated to point to the new address.

---

## 7. File Structure Summary

### New Files

```
src/genesis.cairo              -- StelaGenesis ERC721 contract
src/fee_vault.cairo            -- FeeVault fee distribution contract
src/interfaces/ifee_vault.cairo -- IFeeVault interface (for dispatch)
src/interfaces/igenesis.cairo   -- IStelaGenesis interface
```

### Modified Files

```
src/lib.cairo                  -- Add genesis, fee_vault modules
src/interfaces.cairo           -- Add ifee_vault, igenesis modules
src/stela.cairo                -- Add storage, imports, fee logic, admin functions
src/interfaces/istela.cairo    -- Add set_fee_vault/get_fee_vault to trait
src/errors.cairo               -- (Optional) Add fee-related error constants
```

---

## 8. Testing Strategy

### 8.1 StelaGenesis Tests

- Mint single: verify token minted, payment transferred, total_minted incremented
- Mint batch: verify all tokens minted sequentially
- Sold out: verify revert after 500 mints
- Price enforcement: verify exact payment required
- Admin mint: verify owner bypass of payment/toggle
- Mint disabled: verify revert when toggle is off
- Transfers: verify standard ERC721 transfer/approve behavior

### 8.2 FeeVault Tests

- Single deposit: verify cumulative_per_nft updated correctly (amount/500)
- Multiple deposits (same token): verify cumulative accumulation
- Multiple deposits (different tokens): verify independent tracking
- Claim: verify correct amount transferred, claimed checkpoint updated
- Claim after multiple deposits: verify accumulated correctly
- Claim with no rewards: verify no revert, zero transfer
- Claim batch: verify all NFTs claimed in one tx
- Dust handling: verify deposit of 499 wei (< 500) accumulates as dust, then distributes when another deposit pushes it over
- Ownership check: verify non-owner cannot claim
- Ownership transfer: verify new owner gets accumulated rewards

### 8.3 Stela Fee Split Tests

- settle() with vault: verify 2-way split (relayer 5, vault 20 BPS)
- settle() without vault (zero address): verify legacy relayer-only fee
- redeem() with vault: verify vault gets 10 BPS on ERC20 payout
- redeem() without vault: verify full payout (no deduction)
- redeem() with ERC721 collateral: verify no fee applied
- redeem() with ERC1155 collateral: verify no fee applied
- private settle(): verify fee split works with pool-based transfers
- private redeem(): verify fee deduction on private redemption payout
- Multiple debt assets: verify fee applied per-asset correctly
- Rounding: verify borrower-favorable rounding (floor division)
- Fee vault deposit: verify vault balance increases correctly after settle/redeem

### 8.4 Integration Tests

- Full lifecycle with Genesis: create -> settle -> repay -> redeem, verify all fees collected in vault, NFT holder can claim
- Swap with Genesis fee: settle(duration=0) -> redeem, verify fees
- Multi-lender with Genesis fee: multiple settles, verify fees proportional
- Claim after multiple operations: verify accumulated across multiple settle/redeem cycles

---

## 9. Security Considerations

1. **Reentrancy:** FeeVault `deposit()` is called from within stela's `_issue_debt_with_fee()` which is already inside a reentrancy guard. The vault's `deposit()` calls `transfer_from` (external call) which is standard. The claim functions follow checks-effects-interactions.

2. **Approval race conditions:** Stela approves vault for exact amount before each deposit. No persistent approvals that could be exploited.

3. **Integer overflow:** All fee calculations are bounded by MAX_BPS (10,000). With u256 math, overflow is impossible for any realistic token amount.

4. **Dust loss:** The dust accumulator prevents fee loss from integer division. Maximum dust per token is 499 wei (for 500 NFTs).

5. **Front-running claims:** Not a concern -- each NFT has its own independent claim state. There's no competitive race.

6. **Malicious ERC20 in vault:** The vault accepts any ERC20 via `deposit()`. A malicious token could revert on transfer. This only affects that token's claims, not others. The Stela contract only deposits tokens that are already being used as debt/interest/collateral, so they've already been vetted.

7. **NFT ownership changes during pending claims:** By design, unclaimed fees transfer with NFT ownership. The claim checks `owner_of()` at claim time. This is a feature, not a bug.

8. **Zero total_nfts:** Prevented by constructor assertion. Division by zero is impossible.

---

## 10. Gas Considerations

1. **Vault deposit per settle:** Each debt asset in a settle now requires 3 extra transfers (vault, treasury, borrower) instead of 2 (relayer, borrower). The additional gas cost per debt asset is approximately 1 `transfer_from` + 1 `approve` + 1 external call to `vault.deposit()`.

2. **Redeem fee:** Each redeemed asset now requires 1 extra `approve` + 1 external call to `vault.deposit()` + 1 `transfer` to treasury. This adds roughly 50% overhead per asset to the redeem operation.

3. **Claim:** Claiming fees for one NFT across N tokens requires N `transfer` calls. For a typical setup with 2-3 fee tokens, this is ~3 transfers.

4. **Mitigation:** The batch claim function amortizes the base transaction cost across multiple NFTs.
