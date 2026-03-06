# TYPES.md -- Stela Protocol Types and Structs

All types are defined in `src/types/` and `src/snip12.cairo`.

---

## AssetType (enum)

**File:** `src/types/asset.cairo`

Represents the token standard an asset conforms to.

```cairo
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq, Default)]
pub enum AssetType {
    #[default]
    ERC20,
    ERC721,
    ERC1155,
    ERC4626,
}
```

| Variant | Felt Value | Usage |
|---|---|---|
| `ERC20` | 0 | Fungible tokens. Uses `value` for amount, `token_id` unused (0). |
| `ERC721` | 1 | Non-fungible tokens. Uses `token_id` for NFT ID, `value` unused (0). Forbidden in debt/interest. Forbidden in multi-lender collateral. |
| `ERC1155` | 2 | Semi-fungible tokens. Uses both `token_id` and `value`. Forbidden in debt/interest. Forbidden in multi-lender collateral. |
| `ERC4626` | 3 | Vault shares. Treated as ERC-20 for transfers (`IERC20Dispatcher`). Uses `value` for amount. |

---

## Asset (struct)

**File:** `src/types/asset.cairo`

Represents a single asset in an inscription.

```cairo
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
pub struct Asset {
    pub asset: ContractAddress,    // Token contract address
    pub asset_type: AssetType,     // Token standard
    pub value: u256,               // Token amount (ERC20/ERC4626/ERC1155)
    pub token_id: u256,            // NFT ID (ERC721/ERC1155)
}
```

| Field | Type | Description |
|---|---|---|
| `asset` | `ContractAddress` | The token contract address. Must be non-zero. |
| `asset_type` | `AssetType` | Determines which dispatcher is used for transfers. |
| `value` | `u256` | Token amount for fungible types. Must be > 0 for ERC20/ERC4626/ERC1155. Unused for ERC721. |
| `token_id` | `u256` | Token ID for NFTs. Used by ERC721 and ERC1155. Unused for ERC20/ERC4626. |

**Validation rules:**
- `asset` must not be zero address
- `value` must be > 0 for ERC20, ERC4626, and ERC1155
- ERC721 and ERC1155 are forbidden in debt and interest arrays
- ERC721 and ERC1155 are forbidden in collateral for multi-lender inscriptions

---

## InscriptionParams (struct)

**File:** `src/types/inscription.cairo`

Parameters for creating a new inscription. Passed by the caller to `create_inscription()`.

```cairo
#[derive(Drop, Serde)]
pub struct InscriptionParams {
    pub is_borrow: bool,
    pub debt_assets: Array<Asset>,
    pub interest_assets: Array<Asset>,
    pub collateral_assets: Array<Asset>,
    pub duration: u64,
    pub deadline: u64,
    pub multi_lender: bool,
}
```

| Field | Type | Description |
|---|---|---|
| `is_borrow` | `bool` | `true` = caller is borrower seeking a lender. `false` = caller is lender seeking a borrower. |
| `debt_assets` | `Array<Asset>` | Assets the borrower wants to receive (loan principal). Only ERC20/ERC4626 allowed. Must have at least 1, at most 10. |
| `interest_assets` | `Array<Asset>` | Assets the borrower pays as interest on repayment. Only ERC20/ERC4626. Can be empty (zero-interest loans). At most 10. |
| `collateral_assets` | `Array<Asset>` | Assets locked as collateral in the TBA locker. All asset types allowed (ERC721 only for single-lender). Must have at least 1, at most 10. |
| `duration` | `u64` | Loan duration in seconds. `0` = instant swap (no locker, immediate liquidation). |
| `deadline` | `u64` | Unix timestamp deadline for the inscription to be filled. Must be in the future (`> block_timestamp`). |
| `multi_lender` | `bool` | If `true`, multiple lenders can partially fill. If `false`, single lender fills 100%. |

---

## StoredInscription (struct)

**File:** `src/types/inscription.cairo`

On-chain stored inscription state. Asset arrays are stored separately in indexed maps.

```cairo
#[derive(Drop, Copy, Serde, starknet::Store, PartialEq)]
pub struct StoredInscription {
    pub borrower: ContractAddress,
    pub lender: ContractAddress,
    pub duration: u64,
    pub deadline: u64,
    pub signed_at: u64,
    pub issued_debt_percentage: u256,
    pub is_repaid: bool,
    pub liquidated: bool,
    pub multi_lender: bool,
    pub debt_asset_count: u32,
    pub interest_asset_count: u32,
    pub collateral_asset_count: u32,
}
```

| Field | Type | Description |
|---|---|---|
| `borrower` | `ContractAddress` | Borrower address. Zero if created by a lender and not yet filled. |
| `lender` | `ContractAddress` | Lender address (last lender for multi-lender). Zero if created by borrower and not yet filled. |
| `duration` | `u64` | Loan duration in seconds. `0` = instant swap. |
| `deadline` | `u64` | Unix timestamp for fill expiry. |
| `signed_at` | `u64` | Timestamp of first fill. `0` if unfilled. Repayment window starts here. |
| `issued_debt_percentage` | `u256` | Cumulative BPS filled so far. Max 10,000 (100%). |
| `is_repaid` | `bool` | `true` if the borrower has repaid the loan. |
| `liquidated` | `bool` | `true` if liquidated. Also `true` for instant swaps after fill. |
| `multi_lender` | `bool` | `true` if multiple lenders can partially fill. |
| `debt_asset_count` | `u32` | Number of debt assets stored in indexed map. |
| `interest_asset_count` | `u32` | Number of interest assets stored in indexed map. |
| `collateral_asset_count` | `u32` | Number of collateral assets stored in indexed map. |

**Notes:**
- For multi-lender inscriptions, the `lender` field is meaningless after signing -- lender ownership is tracked via ERC-1155 share balances.
- A zero-initialized struct is returned by `get_inscription()` if the inscription does not exist.

---

## InscriptionOrder (SNIP-12 typed data)

**File:** `src/snip12.cairo`

Off-chain inscription order signed by the borrower. Used in `settle()`.

```cairo
#[derive(Copy, Drop, Hash, Serde)]
pub struct InscriptionOrder {
    pub borrower: ContractAddress,
    pub debt_hash: felt252,
    pub interest_hash: felt252,
    pub collateral_hash: felt252,
    pub debt_count: u32,
    pub interest_count: u32,
    pub collateral_count: u32,
    pub duration: u64,
    pub deadline: u64,
    pub multi_lender: bool,
    pub nonce: felt252,
}
```

| Field | Type | Description |
|---|---|---|
| `borrower` | `ContractAddress` | Signer's address. |
| `debt_hash` | `felt252` | Poseidon hash of the debt asset array (verified against actual assets in `settle()`). |
| `interest_hash` | `felt252` | Poseidon hash of the interest asset array. |
| `collateral_hash` | `felt252` | Poseidon hash of the collateral asset array. |
| `debt_count` | `u32` | Expected number of debt assets (must match actual array length). |
| `interest_count` | `u32` | Expected number of interest assets. |
| `collateral_count` | `u32` | Expected number of collateral assets. |
| `duration` | `u64` | Loan duration in seconds. `0` = instant swap. |
| `deadline` | `u64` | Unix timestamp deadline for the order to be settled. |
| `multi_lender` | `bool` | Whether multiple lenders can partially fill. |
| `nonce` | `felt252` | Borrower's sequential nonce for replay protection (consumed via `NoncesComponent`). |

**SNIP-12 type hash:**
```
"InscriptionOrder"("borrower":"ContractAddress","debt_hash":"felt","interest_hash":"felt","collateral_hash":"felt","debt_count":"u128","interest_count":"u128","collateral_count":"u128","duration":"u128","deadline":"u128","multi_lender":"bool","nonce":"felt")
```

**StructHash implementation:** Uses direct `PoseidonTrait` hashing with type hash prefix.

---

## LendOffer (SNIP-12 typed data)

**File:** `src/snip12.cairo`

Off-chain lend offer signed by the lender. References a specific InscriptionOrder. Used in `settle()`.

```cairo
#[derive(Copy, Drop, Hash, Serde)]
pub struct LendOffer {
    pub order_hash: felt252,
    pub lender: ContractAddress,
    pub issued_debt_percentage: u256,
    pub nonce: felt252,
}
```

| Field | Type | Description |
|---|---|---|
| `order_hash` | `felt252` | SNIP-12 message hash of the `InscriptionOrder` this offer is for. Binds the offer to exact loan terms. |
| `lender` | `ContractAddress` | Signer's address. |
| `issued_debt_percentage` | `u256` | Fill percentage in BPS. Ignored for single-lender orders (always 100%). |
| `nonce` | `felt252` | Lender's sequential nonce. |

**SNIP-12 type hash (includes u256 sub-type):**
```
"LendOffer"("order_hash":"felt","lender":"ContractAddress","issued_debt_percentage":"u256","nonce":"felt")"u256"("low":"u128","high":"u128")
```

**StructHash implementation:** The `u256` field (`issued_debt_percentage`) is encoded as a nested struct hash per SNIP-12: `Poseidon(U256_TYPE_HASH, low, high)`.

---

## SignedOrder (struct)

**File:** `src/types/signed_order.cairo`

Canonical signed order for the matching engine. Used in `fill_signed_order()`, `cancel_order()`.

```cairo
#[derive(Drop, Copy, Serde)]
pub struct SignedOrder {
    pub maker: ContractAddress,
    pub allowed_taker: ContractAddress,
    pub inscription_id: u256,
    pub bps: u256,
    pub deadline: u64,
    pub nonce: felt252,
    pub min_fill_bps: u256,
}
```

| Field | Type | Description |
|---|---|---|
| `maker` | `ContractAddress` | Order creator (could be borrower or lender). |
| `allowed_taker` | `ContractAddress` | Zero = open to anyone. Nonzero = private OTC (only this address can fill). |
| `inscription_id` | `u256` | The inscription being offered for filling. Must already exist on-chain. |
| `bps` | `u256` | Total fill percentage offered (in BPS, max 10,000). |
| `deadline` | `u64` | Unix timestamp for order expiration. Enforced on-chain. |
| `nonce` | `felt252` | Maker nonce. Bump via `cancel_orders_by_nonce()` to invalidate all orders below this threshold. |
| `min_fill_bps` | `u256` | Minimum acceptable partial fill per call. `0` = any amount accepted. |

**SNIP-12 type hash (includes u256 sub-type):**
```
"SignedOrder"("maker":"ContractAddress","allowed_taker":"ContractAddress","inscription_id":"u256","bps":"u256","deadline":"u128","nonce":"felt","min_fill_bps":"u256")"u256"("low":"u128","high":"u128")
```

**StructHash implementation:** All `u256` fields (`inscription_id`, `bps`, `min_fill_bps`) are encoded as nested struct hashes. The `deadline` field is cast to `felt252` via `Into::<u64, felt252>::into()`.

**MUST NOT change after any signature is issued** -- any field addition or reordering invalidates all outstanding signed orders.

