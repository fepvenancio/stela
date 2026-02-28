# EVENTS.md -- Stela Protocol Events

All events emitted by StelaProtocol and LockerAccount contracts. Fields marked with `#[key]` are indexed for efficient filtering.

---

## StelaProtocol Events (15)

### Inscription Lifecycle Events (6)

#### InscriptionCreated

Emitted when a new inscription is created (via `create_inscription()` or `settle()`).

```cairo
struct InscriptionCreated {
    #[key] inscription_id: u256,
    #[key] creator: ContractAddress,
    is_borrow: bool,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Unique inscription identifier. |
| `creator` | Yes | `ContractAddress` | Address that created the inscription. For `settle()`, this is the borrower (not the relayer). |
| `is_borrow` | No | `bool` | `true` if creator is borrower, `false` if creator is lender. Always `true` for `settle()`. |

#### InscriptionSigned

Emitted when an inscription is filled/signed (via `sign_inscription()`, `settle()`, or `fill_signed_order()`).

```cairo
struct InscriptionSigned {
    #[key] inscription_id: u256,
    #[key] borrower: ContractAddress,
    #[key] lender: ContractAddress,
    issued_debt_percentage: u256,
    shares_minted: u256,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Inscription being filled. |
| `borrower` | Yes | `ContractAddress` | Borrower address. |
| `lender` | Yes | `ContractAddress` | Lender address. Zero for private settlements. |
| `issued_debt_percentage` | No | `u256` | Percentage of debt filled in this call (BPS). |
| `shares_minted` | No | `u256` | Number of ERC-1155 shares minted to the lender (before fee shares). |

#### InscriptionCancelled

Emitted when an unfilled inscription is cancelled (via `cancel_inscription()`).

```cairo
struct InscriptionCancelled {
    #[key] inscription_id: u256,
    creator: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Cancelled inscription. |
| `creator` | No | `ContractAddress` | Address that cancelled (must be the original creator). |

#### InscriptionRepaid

Emitted when a borrower repays a loan (via `repay()`).

```cairo
struct InscriptionRepaid {
    #[key] inscription_id: u256,
    repayer: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Repaid inscription. |
| `repayer` | No | `ContractAddress` | Borrower who repaid. |

#### InscriptionLiquidated

Emitted when an expired inscription is liquidated (via `liquidate()`).

```cairo
struct InscriptionLiquidated {
    #[key] inscription_id: u256,
    liquidator: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Liquidated inscription. |
| `liquidator` | No | `ContractAddress` | Address that triggered liquidation (can be anyone). |

#### SharesRedeemed

Emitted when a lender redeems shares for underlying assets (via `redeem()`).

```cairo
struct SharesRedeemed {
    #[key] inscription_id: u256,
    #[key] redeemer: ContractAddress,
    shares: u256,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Inscription whose shares are redeemed. |
| `redeemer` | Yes | `ContractAddress` | Address redeeming shares. |
| `shares` | No | `u256` | Number of shares burned. |

---

### Off-Chain Settlement Events (2)

#### OrderSettled

Emitted when an off-chain order is settled (via `settle()`).

```cairo
struct OrderSettled {
    #[key] inscription_id: u256,
    #[key] borrower: ContractAddress,
    #[key] lender: ContractAddress,
    relayer: ContractAddress,
    relayer_fee_amount: u256,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Newly created inscription. |
| `borrower` | Yes | `ContractAddress` | Borrower address. |
| `lender` | Yes | `ContractAddress` | Lender address. Zero for private settlements. |
| `relayer` | No | `ContractAddress` | Relayer (caller) that submitted the transaction. |
| `relayer_fee_amount` | No | `u256` | Total relayer fee across all debt assets. |

**Note:** `settle()` also emits `InscriptionCreated` and `InscriptionSigned` in the same transaction.

#### PrivateSettled

Emitted when a private (anonymous) settlement occurs (via `settle()` when `lender_commitment != 0`).

```cairo
struct PrivateSettled {
    #[key] inscription_id: u256,
    #[key] lender_commitment: felt252,
    shares_committed: u256,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Inscription settled privately. |
| `lender_commitment` | Yes | `felt252` | The privacy commitment inserted into the Merkle tree. |
| `shares_committed` | No | `u256` | Number of shares committed (not minted as ERC-1155). |

---

### Signed Order Matching Events (3)

#### OrderFilled

Emitted when a signed order is partially or fully filled (via `fill_signed_order()`).

```cairo
struct OrderFilled {
    #[key] inscription_id: u256,
    #[key] order_hash: felt252,
    #[key] taker: ContractAddress,
    fill_bps: u256,
    total_filled_bps: u256,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | The inscription being filled. |
| `order_hash` | Yes | `felt252` | Hash of the signed order (from `StructHash`). |
| `taker` | Yes | `ContractAddress` | Address filling the order. |
| `fill_bps` | No | `u256` | BPS filled in this call. |
| `total_filled_bps` | No | `u256` | Cumulative BPS filled across all fills of this order. |

#### OrderCancelled

Emitted when a specific signed order is cancelled (via `cancel_order()`).

```cairo
struct OrderCancelled {
    #[key] order_hash: felt252,
    maker: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `order_hash` | Yes | `felt252` | Hash of the cancelled order. |
| `maker` | No | `ContractAddress` | Maker who cancelled. |

#### OrdersBulkCancelled

Emitted when a maker bulk-cancels orders by nonce threshold (via `cancel_orders_by_nonce()`).

```cairo
struct OrdersBulkCancelled {
    #[key] maker: ContractAddress,
    new_min_nonce: felt252,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `maker` | Yes | `ContractAddress` | Maker who set the new minimum nonce. |
| `new_min_nonce` | No | `felt252` | New minimum nonce. Orders with nonce below this are invalid. |

---

### Privacy Events (1)

#### PrivateSharesRedeemed

Emitted when shares are privately redeemed via ZK proof (via `private_redeem()`).

```cairo
struct PrivateSharesRedeemed {
    #[key] inscription_id: u256,
    #[key] nullifier: felt252,
    shares: u256,
    recipient: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `inscription_id` | Yes | `u256` | Inscription whose shares are redeemed. |
| `nullifier` | Yes | `felt252` | Nullifier used (prevents double-redemption). |
| `shares` | No | `u256` | Number of shares redeemed. |
| `recipient` | No | `ContractAddress` | Address that received the assets. |

---

## LockerAccount Events (3)

#### LockerUnlocked

Emitted when a locker is unlocked after loan repayment.

```cairo
struct LockerUnlocked {
    #[key] locker: ContractAddress,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `locker` | Yes | `ContractAddress` | The locker TBA address that was unlocked. |

#### AssetsPulled

Emitted when collateral is pulled from a locker during liquidation.

```cairo
struct AssetsPulled {
    #[key] locker: ContractAddress,
    asset_count: u32,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `locker` | Yes | `ContractAddress` | The locker TBA address. |
| `asset_count` | No | `u32` | Number of assets pulled. |

#### AllowedSelectorUpdated

Emitted when a selector is added to or removed from a locker's allowlist.

```cairo
struct AllowedSelectorUpdated {
    #[key] locker: ContractAddress,
    selector: felt252,
    allowed: bool,
}
```

| Field | Indexed | Type | Description |
|---|---|---|---|
| `locker` | Yes | `ContractAddress` | The locker TBA address. |
| `selector` | No | `felt252` | The function selector that was updated. |
| `allowed` | No | `bool` | `true` if added to allowlist, `false` if removed. |

---

## OpenZeppelin Component Events (flattened)

The StelaProtocol event enum includes flattened component events:

| Component Event | Source |
|---|---|
| `ERC1155Event` | ERC-1155 transfers and approvals (`TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI`) |
| `OwnableEvent` | Ownership transfers (`OwnershipTransferred`, `OwnershipTransferStarted`) |
| `SRC5Event` | (No events normally emitted at runtime) |
| `ReentrancyGuardEvent` | (No events normally emitted at runtime) |
| `PausableEvent` | Pause/unpause (`Paused`, `Unpaused`) |
| `NoncesEvent` | (No events normally emitted at runtime) |

These use `#[flat]` annotation, meaning their selector is their own (not nested under the parent enum variant).
