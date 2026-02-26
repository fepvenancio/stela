# Stela Protocol -- Deployment Guide

## Prerequisites

### Required Tools

| Tool | Version | Install |
|---|---|---|
| Scarb | 2.13.1 | [docs.swmansion.com/scarb](https://docs.swmansion.com/scarb/) |
| StarkNet Foundry (snforge) | 0.56.0 | [foundry-rs.github.io/starknet-foundry](https://foundry-rs.github.io/starknet-foundry/) |
| starkli (optional) | latest | For manual deployment and interaction |

Verify your installation:

```bash
scarb --version
# scarb 2.13.1

snforge --version
# snforge 0.56.0
```

---

## Building

### Compile Contracts

```bash
scarb build
```

This compiles both contracts (`StelaProtocol` and `LockerAccount`) and produces Sierra and CASM artifacts in `target/dev/`:

```
target/dev/
  stela_StelaProtocol.contract_class.json       # Sierra (StelaProtocol)
  stela_StelaProtocol.compiled_contract_class.json  # CASM (StelaProtocol)
  stela_LockerAccount.contract_class.json        # Sierra (LockerAccount)
  stela_LockerAccount.compiled_contract_class.json  # CASM (LockerAccount)
```

The `Scarb.toml` is configured with:
- `sierra = true` and `casm = true` under `[[target.starknet-contract]]`
- `allowed-libfuncs-list.name = "experimental"` (required for some features)

### Format Code

```bash
scarb fmt
```

Uses the formatting rules from `Scarb.toml`:
- `sort-module-level-items = true`
- `max-line-length = 120`

---

## Testing

### Run All Tests

```bash
snforge test
```

The test configuration in `Scarb.toml` sets `exit_first = true`, which stops on the first failure.

### Run Specific Test Modules

```bash
# Individual test modules
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
```

### Run a Single Test

```bash
snforge test test_create_inscription::test_create_basic_inscription
```

### Test Coverage

The test suite covers:

| Module | Coverage Area |
|---|---|
| `test_create_inscription` | Inscription creation, parameter validation, asset validation |
| `test_sign_inscription` | Signing/filling, borrower/lender role assignment, share minting |
| `test_repay` | Repayment flow, timing checks, collateral unlock |
| `test_liquidate` | Liquidation flow, timing checks, collateral pull |
| `test_redeem` | Share redemption for repaid and liquidated inscriptions |
| `test_otc_swap` | Duration=0 instant swap flow |
| `test_multi_lender` | Multiple partial fills, share proportionality |
| `test_security` | Access control, pause, double-action prevention |
| `test_e2e` | Full end-to-end lifecycle tests |
| `test_utils` | Share math functions (convert_to_shares, convert_to_percentage, etc.) |
| `test_hash_compat` | SNIP-12 hash compatibility |

### Debug Mode

The `Scarb.toml` enables debug features in dev profile:

```toml
[profile.dev.cairo]
unstable-add-statements-functions-debug-info = true
unstable-add-statements-code-locations-debug-info = true
panic-backtrace = true
```

These provide detailed backtraces on test failures.

---

## Deployment

### Overview

Deploying Stela requires multiple contracts deployed in a specific order:

1. **LockerAccount** -- Declare only (class hash needed, not deployed directly).
2. **Inscription NFT** -- An ERC-721 contract with a `mint(to, token_id)` function.
3. **SNIP-14 Registry** -- A TBA registry contract (e.g., Horus Labs TBA).
4. **StelaProtocol** -- The core contract, referencing all of the above.

### Step 1: Declare LockerAccount

The LockerAccount is never deployed directly. Its class hash is used by the SNIP-14 registry to deploy instances on demand.

```bash
starkli declare target/dev/stela_LockerAccount.contract_class.json \
  --account <YOUR_ACCOUNT> \
  --network <sepolia|mainnet>
```

Save the returned class hash. This is the `implementation_hash` parameter for the StelaProtocol constructor.

### Step 2: Deploy (or Identify) Inscription NFT

You need an ERC-721 contract that implements `IERC721Mintable`:

```cairo
trait IERC721Mintable<TContractState> {
    fn mint(ref self: TContractState, to: ContractAddress, token_id: u256);
}
```

The Stela protocol calls `nft.mint(borrower, inscription_id)` on first sign. The NFT contract must either grant the Stela contract minting permissions or be designed to allow open minting from the protocol address.

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

If using the Horus Labs TBA registry, it should already be deployed on Sepolia and Mainnet. Otherwise, deploy your own.

### Step 4: Deploy StelaProtocol

The constructor requires four parameters:

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
- Initializes ERC-1155 with an empty base URI.
- Sets the owner via OwnableComponent.
- Sets the default protocol fee to 10 BPS (0.1%).
- Sets the treasury to the owner address.

---

## Post-Deployment Configuration

After deployment, the owner should configure the protocol. All of these are owner-only functions.

### Set Treasury Address

If the treasury should differ from the owner:

```
set_treasury(treasury: ContractAddress)
```

The treasury receives fee shares (ERC-1155) on every inscription signing.

### Set Protocol Fee

To adjust the protocol fee (default is 10 BPS = 0.1%):

```
set_inscription_fee(fee: u256)
```

The fee is in BPS. Maximum allowed value is 10,000 (100%).

### Set Relayer Fee

To enable off-chain settlement with relayer compensation:

```
set_relayer_fee(fee: u256)
```

The fee is in BPS, deducted from the lender's debt transfer and sent to the relayer. Default is 0.

### Update Implementation Hash

If the LockerAccount contract is upgraded:

```
set_implementation_hash(implementation_hash: felt252)
```

This only affects newly created lockers. Existing lockers continue using their original class hash.

### Configure Locker Allowed Selectors

To enable borrowers to vote/delegate with locked collateral:

```
set_locker_allowed_selector(locker: ContractAddress, selector: felt252, allowed: bool)
```

This must be called per-locker. Common selectors to allowlist:

| Function | Selector Expression |
|---|---|
| `vote` | `selector!("vote")` |
| `delegate` | `selector!("delegate")` |

Note: The locker address must be a registered locker (`is_locker` must be true), which happens automatically when a TBA is created during `sign_inscription`.

### Update External Contracts

If the NFT contract or registry needs to change:

```
set_inscriptions_nft(inscriptions_nft: ContractAddress)
set_registry(registry: ContractAddress)
```

Both reject zero addresses.

### Pause/Unpause

In case of emergency:

```
pause()    -- Halts create, sign, repay, liquidate, redeem, settle
unpause()  -- Resumes normal operation
```

---

## Deployment Checklist

### Pre-Deployment

- [ ] All tests pass: `snforge test`
- [ ] Code is formatted: `scarb fmt --check`
- [ ] Contracts compile cleanly: `scarb build`
- [ ] Deployer account is funded with sufficient ETH for gas
- [ ] NFT contract is deployed and accessible
- [ ] SNIP-14 registry is deployed and accessible

### Deployment

- [ ] LockerAccount class hash declared
- [ ] StelaProtocol deployed with correct constructor arguments
- [ ] Verify constructor parameters are correct (owner, NFT, registry, implementation hash)

### Post-Deployment

- [ ] `set_treasury` called if treasury differs from owner
- [ ] `set_inscription_fee` set to desired value (or leave default 10 BPS)
- [ ] `set_relayer_fee` set if off-chain settlement is enabled
- [ ] NFT contract grants minting permissions to StelaProtocol address (if required by NFT implementation)
- [ ] Verify protocol is not paused: call `is_paused()` returns false
- [ ] Verify configuration: call `get_inscription_fee()`, `get_treasury()`, `get_relayer_fee()`
- [ ] Test a full lifecycle on testnet: create, sign, repay, redeem

### Sepolia Testing Recommendations

1. Deploy mock ERC-20 tokens for testing (the `src/mocks/mock_erc20.cairo` contract can be used).
2. Create a test inscription with a short duration (e.g., 60 seconds).
3. Sign the inscription from a second account.
4. Verify collateral is locked in the TBA (check TBA address via `get_locker`).
5. Wait for duration to pass, then test liquidation.
6. Alternatively, repay before duration expires and test redemption.
7. Test the cancel flow: create an inscription, then cancel before signing.
8. Test the OTC swap flow: create with duration=0, sign, redeem immediately.

---

## Contract Addresses

After deployment, record all addresses:

| Contract | Sepolia | Mainnet |
|---|---|---|
| StelaProtocol | `0x...` | `0x...` |
| LockerAccount (class hash) | `0x...` | `0x...` |
| Inscription NFT | `0x...` | `0x...` |
| SNIP-14 Registry | `0x...` | `0x...` |
| Treasury | `0x...` | `0x...` |

Update the `@stela/core` package (`packages/core/src/constants.ts`) in the monorepo with these addresses after deployment.

---

## Upgradeability Notes

- **StelaProtocol** is not upgradeable. A new deployment is required for contract logic changes.
- **LockerAccount** instances are deployed via the registry. Changing `implementation_hash` only affects new lockers. Existing lockers are immutable.
- **Configuration** (fees, treasury, registry, NFT contract, implementation hash) can be updated by the owner without redeployment.
