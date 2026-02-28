# DEPLOYMENT.md -- Stela Protocol Deployment Guide

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Scarb | 2.13.1 | [docs.swmansion.com/scarb](https://docs.swmansion.com/scarb/) |
| StarkNet Foundry (snforge) | 0.56.0 | [foundry-rs.github.io/starknet-foundry](https://foundry-rs.github.io/starknet-foundry/) |
| starkli (optional) | latest | For manual deployment and interaction |

```bash
scarb --version   # scarb 2.13.1
snforge --version # snforge 0.56.0
```

---

## Building

```bash
scarb build
```

Produces Sierra and CASM artifacts in `target/dev/`:

```
target/dev/
  stela_StelaProtocol.contract_class.json
  stela_StelaProtocol.compiled_contract_class.json
  stela_LockerAccount.contract_class.json
  stela_LockerAccount.compiled_contract_class.json
```

`Scarb.toml` config: `sierra = true`, `casm = true`, `allowed-libfuncs-list.name = "experimental"`.

```bash
scarb fmt         # format code
scarb fmt --check # verify formatting
```

---

## Testing

```bash
snforge test
```

`exit_first = true` in `Scarb.toml` stops on first failure.

### Test Modules

```bash
snforge test test_create_inscription
snforge test test_sign_inscription
snforge test test_repay
snforge test test_liquidate
snforge test test_redeem
snforge test test_otc_swap
snforge test test_multi_lender
snforge test test_security
snforge test test_e2e
snforge test test_utils
snforge test test_hash_compat
snforge test test_private_settle
snforge test test_settle
```

### Debug Mode

The `[profile.dev.cairo]` section enables:
- `unstable-add-statements-functions-debug-info = true`
- `unstable-add-statements-code-locations-debug-info = true`
- `panic-backtrace = true`

---

## Deployment Steps

### Step 1: Declare LockerAccount

The LockerAccount is never deployed directly. Its class hash is used by the registry to deploy instances on demand.

```bash
starkli declare target/dev/stela_LockerAccount.contract_class.json \
  --account <YOUR_ACCOUNT> \
  --network <sepolia|mainnet>
```

Save the returned class hash as `implementation_hash`.

### Step 2: Deploy (or Identify) Inscription NFT

Need an ERC-721 contract implementing `IERC721Mintable`:

```cairo
trait IERC721Mintable<TContractState> {
    fn mint(ref self: TContractState, to: ContractAddress, token_id: u256);
}
```

The protocol calls `nft.mint(borrower, inscription_id)` on first sign. The NFT contract must grant Stela minting permissions.

### Step 3: Deploy (or Identify) SNIP-14 Registry

The registry must implement `IRegistry`:

```cairo
trait IRegistry<TContractState> {
    fn create_account(
        ref self: TContractState,
        implementation_hash: felt252,
        token_contract: ContractAddress,
        token_id: u256,
    ) -> ContractAddress;

    fn get_account(
        self: @TContractState,
        implementation_hash: felt252,
        token_contract: ContractAddress,
        token_id: u256,
    ) -> ContractAddress;
}
```

### Step 4: Deploy StelaProtocol

Constructor parameters:

| Parameter | Type | Description |
|---|---|---|
| `owner` | `ContractAddress` | Admin address (receives ownership, default treasury) |
| `inscriptions_nft` | `ContractAddress` | ERC-721 NFT contract address |
| `registry` | `ContractAddress` | SNIP-14 TBA registry address |
| `implementation_hash` | `felt252` | LockerAccount class hash from Step 1 |

```bash
starkli deploy target/dev/stela_StelaProtocol.contract_class.json \
  <OWNER_ADDRESS> \
  <NFT_CONTRACT_ADDRESS> \
  <REGISTRY_ADDRESS> \
  <LOCKER_CLASS_HASH> \
  --account <YOUR_ACCOUNT> \
  --network <sepolia|mainnet>
```

The constructor automatically:
- Initializes ERC-1155 with empty base URI
- Sets owner via OwnableComponent
- Sets default protocol fee to 10 BPS (0.1%)
- Sets treasury to the owner address

---

## Post-Deployment Configuration

All owner-only functions.

### Set Treasury Address

```
set_treasury(treasury: ContractAddress)
```

If treasury should differ from owner. Receives fee shares (ERC-1155) on every signing.

### Set Protocol Fee

```
set_inscription_fee(fee: u256)
```

Default is 10 BPS (0.1%). Maximum 10,000 (100%).

### Set Relayer Fee

```
set_relayer_fee(fee: u256)
```

For off-chain settlement. Deducted from lender's debt transfer, sent to relayer. Default is 0.

### Set Privacy Pool

```
set_privacy_pool(privacy_pool: ContractAddress)
```

Zero address disables privacy features. When set, `settle()` supports private settlement (`lender_commitment != 0`, anonymous lender) and `private_redeem()` becomes available for ZK-verified redemption.

### Update Implementation Hash

```
set_implementation_hash(implementation_hash: felt252)
```

Only affects newly created lockers. Existing lockers keep their original class hash.

### Configure Locker Allowed Selectors

```
set_locker_allowed_selector(locker: ContractAddress, selector: felt252, allowed: bool)
```

Per-locker. Common selectors: `vote`, `delegate`. The locker address must be a registered locker (`is_locker` must be true).

### Update External Contracts

```
set_inscriptions_nft(inscriptions_nft: ContractAddress)
set_registry(registry: ContractAddress)
```

Both reject zero addresses.

### Pause/Unpause

```
pause()    -- Halts create, sign, repay, liquidate, redeem, settle, fill_signed_order, private_redeem
unpause()  -- Resumes normal operation
```

---

## Contract Addresses (Sepolia)

| Contract | Address |
|---|---|
| StelaProtocol (current, deposit-privacy) | `0x00b7deedb4ab03d94f54da2e7c911c2336b19c2a4610eb98f55cd7be5a53ece0` |
| StelaPrivacyPool | `0x002579e670f80cca558236c95762dd5b94ae017b6ed92df65b74b61b539cdec7` |
| StelaProtocol (previous, privacy-enabled) | `0x00c667d12113011a05f6271cc4bd9e7f4c3c5b90a093708801955af5a5b1e6d5` |
| StelaProtocol (older) | `0x021e81956fccd8463342ff7e774bf6616b40e242fe0ea09a6f38735a604ea0e0` |
| LockerAccount (class hash) | `0x1a42b6c860becbb16fa5cd936576b98bca8e2ce26c3e279705cdf328ad4e8a5` |
| Inscription NFT (MockERC721) | `0x04f2345306bf8ef1c8c1445661354ef08421aa092459445a5d6b46641237e943` |
| SNIP-14 Registry (MockRegistry) | `0x0499c5c4929b22fbf1ebd8c500f570b2ec5bd8a43a84ee63e92bf8ac7f9f422b` |
| Mock USDC (debt token) | `0x034a0cf09c79e7f20fb2136212f27b7dd88e91f9a24b2ac50c5c41ff6b30c59d` |
| Mock WETH (collateral token) | `0x07e86764396d61d2179cd1a48033fa4f30897cb172464961a80649aff4da9bdd` |
| Mock DAI (interest token) | `0x0479f31a23241b1337375b083099bd1672716edbf908b1b30148a648657a1cee` |

Deployer: `0x005441affcd25fe95554b13690346ebec62a27282327dd297cab01a897b08310`

Update `@stela/core` (`packages/core/src/constants.ts`) with these addresses after deployment.

---

## Deployment Checklist

### Pre-Deployment

- [ ] All tests pass: `snforge test`
- [ ] Code formatted: `scarb fmt --check`
- [ ] Contracts compile: `scarb build`
- [ ] Deployer account funded with ETH
- [ ] NFT contract deployed and accessible
- [ ] SNIP-14 registry deployed and accessible

### Deployment

- [ ] LockerAccount class hash declared
- [ ] StelaProtocol deployed with correct constructor arguments
- [ ] Constructor parameters verified (owner, NFT, registry, implementation hash)

### Post-Deployment

- [ ] `set_treasury` if treasury differs from owner
- [ ] `set_inscription_fee` set to desired value (or leave default 10 BPS)
- [ ] `set_relayer_fee` set if off-chain settlement is enabled
- [ ] `set_privacy_pool` set if privacy features are enabled
- [ ] NFT contract grants minting permissions to StelaProtocol address
- [ ] `is_paused()` returns false
- [ ] Verify: `get_inscription_fee()`, `get_treasury()`, `get_relayer_fee()`, `get_privacy_pool()`
- [ ] Test full lifecycle on testnet: create, sign, repay, redeem

### Sepolia Testing

1. Deploy mock ERC-20 tokens (`src/mocks/mock_erc20.cairo`)
2. Create test inscription with short duration (60 seconds)
3. Sign from second account
4. Verify collateral locked in TBA (`get_locker`)
5. Wait for duration, test liquidation
6. Alternatively: repay before duration, test redemption
7. Test cancel flow: create, cancel before signing
8. Test OTC swap: create with duration=0, sign, redeem immediately

---

## Upgradeability

- **StelaProtocol** is not upgradeable. New deployment required for logic changes.
- **LockerAccount** instances deployed via registry. Changing `implementation_hash` only affects new lockers.
- **Configuration** (fees, treasury, registry, NFT, implementation hash, privacy pool) can be updated by owner without redeployment.
