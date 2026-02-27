# ARCHITECTURE.md — Stela Cairo Contract Architecture

## Contract Structure

```
src/
├── lib.cairo                     # Root module — declares all submodules
├── stela.cairo                   # Core protocol contract
├── locker_account.cairo          # SNIP-14 token-bound account (collateral locker)
├── types/
│   ├── mod.cairo                 # Types module declarations
│   ├── asset.cairo               # AssetType enum, Asset struct
│   └── inscription.cairo           # Inscription, InscriptionParams structs
├── errors.cairo                  # Protocol error constants
├── interfaces/
│   ├── mod.cairo                 # Interface module declarations
│   ├── istela.cairo              # IStelaProtocol trait
│   └── ilocker.cairo             # ILockerAccount trait
└── lib/
    ├── mod.cairo                 # Lib module declarations
    └── share_math.cairo          # Share conversion math utilities
```

## Contract: Stela (stela.cairo)

The core protocol contract. Responsibilities:
- Inscription creation and storage
- Inscription matching (signing/filling)
- Collateral locking via TBA creation
- Debt issuance to borrowers
- Repayment processing
- Liquidation triggering
- Share-based redemption for lenders

### Components Used
- **OpenZeppelin ERC1155Component**: Lender shares (each inscription ID = token ID)
- **OpenZeppelin OwnableComponent**: Admin functions (fee updates, treasury changes)
- **ReentrancyGuard**: Protect against reentrancy in sign/repay/liquidate/redeem

### Storage Layout

Per-inscription escrow tracking: After repayment, debt+interest tokens sit in the Stela contract. Since multiple inscriptions may use the same token, the contract MUST track per-inscription balances to prevent cross-inscription drainage during redemption. Storage maps keyed by (inscription_id, asset_index):

```cairo
inscription_debt_balance: Map<(u256, u32), u256>
inscription_interest_balance: Map<(u256, u32), u256>
inscription_collateral_balance: Map<(u256, u32), u256>
```

**Redemption uses pro-rata share math, NOT percentage-based:**
```cairo
amount = tracked_balance * shares / total_supply  // CORRECT
// NOT: amount = scale_by_percentage(tracked_balance, convert_to_percentage(...))
```
The tracked balances already reflect partial fills, so using `convert_to_percentage` would double-count.

```cairo
#[storage]
struct Storage {
    // Component storage
    #[substorage(v0)]
    erc1155: ERC1155Component::Storage,
    #[substorage(v0)]
    ownable: OwnableComponent::Storage,

    // Protocol storage
    inscriptions: Map<u256, StoredInscription>,     // inscriptionId → inscription data
    lockers: Map<u256, ContractAddress>,          // inscriptionId → TBA address
    is_locker: Map<ContractAddress, bool>,        // TBA address → bool
    total_supply: Map<u256, u256>,                // inscriptionId → total shares minted
    inscription_fee: u256,                          // protocol fee in BPS
    treasury: ContractAddress,                    // fee recipient
    inscriptions_nft: ContractAddress,              // NFT contract for inscription ownership
    registry: ContractAddress,                    // SNIP-14 registry
    implementation_hash: felt252,                 // locker account class hash
}
```
### Known Constraints

NFT collateral + multi-lender: ERC721 assets cannot be partially transferred. If an inscription uses NFT collateral and multi_lender=true, the NFT must be transferred on the FIRST fill only (when issued_debt_percentage goes from 0 to >0). Subsequent lenders share the claim on the already-locked NFT.
Lender field semantics: For single-lender inscriptions, inscription.lender stores the actual lender. For multi-lender inscriptions, this field is meaningless after signing — lender ownership is tracked via ERC1155 balances. Do NOT overwrite inscription.lender on subsequent fills.


### Important Design Note: Storing Dynamic Arrays

Cairo/StarkNet storage doesn't directly support dynamic arrays in structs.
For the Inscription struct which contains Asset arrays (debt_assets, interest_assets, collateral_assets),
we have two options:

**Option A — Flatten into indexed maps:**
```cairo
// Store asset count
inscription_debt_asset_count: Map<u256, u32>,
// Store each asset by index
inscription_debt_assets: Map<(u256, u32), StoredAsset>,
```

**Option B — Use StorageVec (if available in current Cairo version)**

Option A is more explicit and reliable. Use it unless StorageVec is confirmed stable.

## Contract: LockerAccount (locker_account.cairo)

A custom StarkNet account contract that serves as the token-bound account (TBA) for holding inscription collateral.

### Key Behaviors
1. **Normal account functionality**: Can execute arbitrary calls (voting, delegation, claiming)
2. **Blocked selectors**: Rejects calls to transfer/approve functions on token contracts
3. **Stela-only asset movement**: Only the Stela contract can call `pull_assets` and `unlock`
4. **Owned by NFT**: Via SNIP-14, this account is owned by the inscription NFT

### Blocked Function Selectors
On StarkNet, selectors are computed as `sn_keccak(function_name)`. OpenZeppelin Cairo uses
dual dispatch (both snake_case AND camelCase selectors). ALL variants must be blocked:

**ERC20 (snake_case + camelCase):**
- `transfer`, `transfer_from` / `transferFrom`, `approve`
- `increase_allowance` / `increaseAllowance`, `decrease_allowance` / `decreaseAllowance`

**ERC721/ERC1155 (snake_case + camelCase):**
- `safe_transfer_from` / `safeTransferFrom`
- `set_approval_for_all` / `setApprovalForAll`

**ERC1155 batch:**
- `safe_batch_transfer_from` / `safeBatchTransferFrom`

**Destructive / bypass:**
- `burn`, `burn_from` / `burnFrom`
- `permit` (gasless approval bypass)
- `withdraw`, `redeem` (ERC4626 vault functions)

### Implementation Note
Cairo accounts define
`__validate__` and `__execute__` natively. The restriction logic goes in `__execute__`:

```cairo
fn __execute__(ref self: ContractState, calls: Array<Call>) -> Array<Span<felt252>> {
    if !self.unlocked.read() {
        // Check each call's selector against blocked list
        // Revert if any call targets a blocked selector
    }
    // Forward calls normally
}
```

## Asset Transfer Pattern

The `_process_payment` internal function handles all asset movements. It must handle 4 asset types:

```
AssetType::ERC20   → IERC20Dispatcher.transfer_from / transfer
AssetType::ERC721  → IERC721Dispatcher.transfer_from
AssetType::ERC1155 → IERC1155Dispatcher.safe_transfer_from
AssetType::ERC4626 → Same as ERC20 (vault shares are ERC20-compatible)
```

Each payment is scaled by `issued_debt_percentage / MAX_BPS` for partial fills.

## Inscription ID Generation

Deterministic hash of all inscription parameters:
```
inscription_id = keccak256(
    borrower,
    lender,
    debt_assets,
    interest_assets,
    collateral_assets,
    duration,
    deadline,
    block_timestamp  // ensures uniqueness for repeated terms
)
```

Use `poseidon_hash` on StarkNet (native and cheap) instead of keccak256.

## Testing Strategy

Tests use StarkNet Foundry (snforge) with:
- Mock ERC20/ERC721/ERC1155 contracts for token interactions
- `start_cheat_caller_address` for impersonating different users
- `start_cheat_block_timestamp` for time manipulation
- Contract deployment via `declare` and `deploy`

Test accounts:
- BORROWER: Creates inscriptions and locks collateral
- LENDER_1: Fills inscriptions (primary)
- LENDER_2: Fills inscriptions (for multi-lender tests)
- ADMIN: Deploys contracts, sets treasury
