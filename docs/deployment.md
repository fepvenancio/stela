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
- Sets treasury to the owner address

---

## Post-Deployment Configuration

All owner-only functions.

### Set Treasury Address

```
set_treasury(treasury: ContractAddress)
```

If treasury should differ from owner. Receives fee shares (ERC-1155) on every signing.

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
pause()    -- Halts create, sign, repay, liquidate, redeem, settle, fill_signed_order
unpause()  -- Resumes normal operation
```

---

## Contract Addresses (Sepolia)

### Current Deployment (pro-rata-interest-2026-03-12)

| Contract | Address |
|---|---|
| **StelaProtocol** | `0x0109c6caae0c5b4da6e063ed6c02ae784be05aa90806501a48dcfbb213bd7c03` |
| **StelaGenesis NFT** | `0x05acfbb98a9f8d2e177886fa02f5f329b254f6e333ab430ef53e25f4bbfbc8a3` |
| LockerAccount (class hash) | `0xaf086083964e1590d9956bf824d22029ea2c791d1fe94e1e64d72154ac5294` |
| Inscription NFT (MockERC721) | `0x04f2345306bf8ef1c8c1445661354ef08421aa092459445a5d6b46641237e943` |
| SNIP-14 Registry (MockRegistry) | `0x0499c5c4929b22fbf1ebd8c500f570b2ec5bd8a43a84ee63e92bf8ac7f9f422b` |
| Mock USDC (debt token) | `0x034a0cf09c79e7f20fb2136212f27b7dd88e91f9a24b2ac50c5c41ff6b30c59d` |
| Mock WETH (collateral token) | `0x07e86764396d61d2179cd1a48033fa4f30897cb172464961a80649aff4da9bdd` |
| Mock DAI (interest token) | `0x0479f31a23241b1337375b083099bd1672716edbf908b1b30148a648657a1cee` |

Deployer: `0x005441affcd25fe95554b13690346ebec62a27282327dd297cab01a897b08310`

### Previous Deployments (do not use)

| Contract | Address | Tag |
|---|---|---|
| StelaProtocol | `0x03e88d289b9ce13e5d6e6ca5159930f9227b08cfbd004231a09a1d6f48568973` | genesis-fee-vault |
| StelaProtocol | `0x038a0b195e011fbfd75e9bce9bbc4137ebc5296882e11c5769c333b90bda4f89` | fee-overhaul-2026-03-07 |
| StelaProtocol | `0x00b7deedb4ab03d94f54da2e7c911c2336b19c2a4610eb98f55cd7be5a53ece0` | deposit-privacy |
| StelaProtocol | `0x00c667d12113011a05f6271cc4bd9e7f4c3c5b90a093708801955af5a5b1e6d5` | privacy-enabled |
| StelaProtocol | `0x021e81956fccd8463342ff7e774bf6616b40e242fe0ea09a6f38735a604ea0e0` | original |

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

### Genesis NFT Deployment

StelaGenesis constructor takes `(owner, payment_token, mint_recipient, treasury, base_uri)`:

- `treasury` receives 50 reserve NFTs (token IDs 1-50) at deployment — hardcoded as `TREASURY_RESERVE = 50`
- Public mint is capped at 5 per wallet (`MAX_PER_WALLET = 5`), 250 NFTs available (IDs 51-300)
- Total supply: 300
- Mint price: 1,000 STRK
- Mint starts disabled; owner calls `set_mint_enabled(true)` then `renounce_ownership()`
- After renounce: mint price (1,000 STRK), mint status, base URI, and admin mint are all permanently locked

Deployment sequence:
1. Deploy **StelaGenesis** — 50 NFTs auto-mint to treasury in constructor
2. Call `stela.set_treasury(treasury_address)` on the Stela contract
3. Call `stela.set_genesis_contract(genesis_address)` on the Stela contract
4. Call `genesis.set_mint_enabled(true)` to open public minting
5. Call `genesis.renounce_ownership()` — permanent, irreversible

### Post-Deployment

- [ ] `set_treasury` if treasury differs from owner
- [ ] `set_genesis_contract` set if fee discount system is enabled
- [ ] NFT contract grants minting permissions to StelaProtocol address
- [ ] `is_paused()` returns false
- [ ] Verify: `get_treasury()`, `get_genesis_contract()`
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
- **Configuration** (treasury, registry, NFT, implementation hash, genesis contract) can be updated by owner without redeployment. Fee rates are hardcoded constants.

---

## CRITICAL: Full Stack Reset After Every New Deployment

**Every new Stela contract deployment requires a FULL RESET of the entire off-chain stack.**
This is NOT optional. Missing any step causes silent failures that are extremely hard to debug.

### Why Everything Breaks

1. **Nonces reset to 0** — New contract's NoncesComponent starts at 0 for all addresses.
   Old orders in D1 reference consumed nonces (e.g., nonce=4). The bot's `expireStaleNonceOrders()`
   sees the mismatch and immediately expires them. Server-side `verify-nonce.ts` also rejects them.

2. **SNIP-12 domain changes** — Typed data signatures include the contract address in the domain.
   Old signatures are invalid against the new contract even if the nonce matches.

3. **On-chain data is gone** — Inscriptions, lockers, share balances on the old contract don't exist
   on the new one. D1 data referencing old inscription IDs is orphaned.

4. **Build caches bake in addresses** — Next.js bakes `NEXT_PUBLIC_*` env vars into both client
   AND server bundles at build time. Turbo cache can serve stale builds even after source changes.

### What Must Be Reset

**See `stela-app/CLAUDE.md` for the complete step-by-step checklist.** Summary:

| What | Where | Why |
|------|-------|-----|
| Contract address | 7 config files across stela-app repo | All services read from different places |
| Contract address | stela-sdk-ts `constants.ts` | SDK is source of truth |
| ABI | `packages/core/src/abi/stela.json` + SDK | New entrypoints/events |
| D1 orders + offers | `DELETE FROM order_offers; DELETE FROM orders` | Signed against old contract |
| D1 inscriptions + events | `DELETE FROM inscription_events, inscription_assets, ...` | Old contract data |
| D1 indexer cursor | `DELETE FROM _meta WHERE key='last_block'` | Re-index from block 0 |
| D1 bot lock | `DELETE FROM _meta WHERE key='bot_lock'` | Prevent stuck lock |
| Next.js build cache | `rm -rf .next .open-next .turbo node_modules/.cache` | Baked-in old addresses |
| Web app | `pnpm run deploy` from `apps/web/` | NOT just `pnpm build` |
| Bot worker | `npx wrangler@3 deploy` from `workers/bot/` | New contract address |
| Indexer worker | `npx wrangler@3 deploy` from `workers/indexer/` | New contract address |
| Railway Apibara indexer | Update `STELA_ADDRESS` env var + redeploy | New contract address |

### Post-Deployment Wiring

After deploying a new Stela contract, call these admin functions from the `starkMfer` account:

```bash
# 1. Set treasury address
sncast --account starkMfer invoke \
  --contract-address <NEW_STELA_ADDRESS> \
  --function set_treasury \
  --arguments <TREASURY_ADDRESS>

# 2. Link Genesis NFT (enables fee discounts)
sncast --account starkMfer invoke \
  --contract-address <NEW_STELA_ADDRESS> \
  --function set_genesis_contract \
  --arguments <GENESIS_NFT_ADDRESS>

# 3. Verify everything
sncast --account starkMfer call --contract-address <NEW_STELA_ADDRESS> --function get_treasury
sncast --account starkMfer call --contract-address <NEW_STELA_ADDRESS> --function get_genesis_contract
```
