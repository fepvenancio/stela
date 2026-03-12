# CLAUDE.md — Stela Monorepo Build Instructions

## Project Overview

Stela is a P2P lending/inscriptions protocol on StarkNet. The contracts are in a separate repo
(`stela-contracts/`). This repo contains everything else: frontend, indexer, and liquidation bot.

Read this entire file before writing any code.

---

## Repo Structure

```
stela/                          ← this repo
├── packages/
│   └── core/                  ← shared types, ABI, constants
├── apps/
│   ├── web/                   ← Next.js frontend
│   ├── indexer/               ← Apibara event indexer
│   └── bot/                   ← liquidation bot
├── package.json               ← pnpm workspace root
├── pnpm-workspace.yaml
└── turbo.json
```

---

## Toolchain

```
Node.js:     22+
Package mgr: pnpm (workspaces)
Build:       Turborepo
Language:    TypeScript strict mode everywhere
```

---

## Package Manager Setup

```yaml
# pnpm-workspace.yaml
packages:
  - 'apps/*'
  - 'packages/*'
```

```json
// turbo.json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": { "dependsOn": ["^build"], "outputs": [".next/**", "dist/**"] },
    "dev": { "cache": false, "persistent": true },
    "lint": {}
  }
}
```

---

## Package: @stela/core

**Purpose:** Single source of truth for types, ABI, and contract addresses.
Every app imports from here. Never duplicate these across apps.

```
packages/core/
├── src/
│   ├── abi/
│   │   └── stela.json         ← copied from contracts build output
│   ├── types.ts               ← Inscription, Asset, AssetType etc
│   ├── constants.ts           ← addresses, MAX_BPS
│   └── index.ts               ← re-exports everything
└── package.json
```

### Types

```typescript
// packages/core/src/types.ts

export type AssetType = 'ERC20' | 'ERC721' | 'ERC1155' | 'ERC4626'

export type InscriptionStatus =
  | 'open'        // issued_debt_percentage == 0
  | 'partial'     // 0 < issued_debt_percentage < MAX_BPS, multi_lender only
  | 'filled'      // issued_debt_percentage == MAX_BPS, not yet repaid/liquidated
  | 'repaid'
  | 'liquidated'
  | 'expired'     // filled, past deadline+duration, not liquidated yet (needs bot)
  | 'cancelled'

export interface Asset {
  asset: string        // contract address as hex string
  asset_type: AssetType
  value: bigint        // token amount (ERC20/ERC1155/ERC4626)
  token_id: bigint     // NFT ID (ERC721/ERC1155)
}

export interface Inscription {
  id: string           // u256 as 0x-prefixed hex string
  borrower: string     // ContractAddress as hex
  lender: string
  duration: bigint     // seconds
  deadline: bigint     // unix timestamp
  signed_at: bigint    // set on first sign_inscription, 0 if unsigned
  issued_debt_percentage: bigint  // BPS, max 10_000
  is_repaid: boolean
  liquidated: boolean
  multi_lender: boolean
  debt_asset_count: number
  interest_asset_count: number
  collateral_asset_count: number
  status: InscriptionStatus  // computed by indexer, NOT from contract
}

export interface InscriptionEvent {
  inscription_id: string
  event_type: 'created' | 'signed' | 'cancelled' | 'repaid' | 'liquidated' | 'redeemed'
  tx_hash: string
  block_number: bigint
  timestamp: bigint
  data: Record<string, unknown>
}
```

### Constants

```typescript
// packages/core/src/constants.ts

export const MAX_BPS = 10_000n
export const VIRTUAL_SHARE_OFFSET = 10_000_000_000_000_000n // 1e16

export const STELA_ADDRESS = {
  sepolia: '0x0',   // fill in after deployment
  mainnet: '0x0',   // fill in after deployment
} as const

export type Network = keyof typeof STELA_ADDRESS
```

### ABI Sync

After every contract build, run:
```bash
pnpm sync-abi
# copies target/dev/stela_StelaProtocol.contract_class.json
# into packages/core/src/abi/stela.json
# script lives in root package.json scripts
```

---

## App: web (Next.js Frontend)

### Stack
```
Next.js 15 (App Router)
TypeScript strict
Tailwind CSS 4
starknet.js v6
@starknet-react/core v3
get-starknet-core v4
```

### Structure
```
apps/web/
├── src/
│   ├── app/
│   │   ├── layout.tsx
│   │   ├── providers.tsx        ← StarknetConfig wrapper
│   │   ├── page.tsx             ← browse open inscriptions
│   │   ├── create/
│   │   │   └── page.tsx         ← create inscription form
│   │   ├── inscription/
│   │   │   └── [id]/
│   │   │       └── page.tsx     ← inscription detail + actions
│   │   └── portfolio/
│   │       └── page.tsx         ← user's positions
│   ├── components/
│   │   ├── WalletButton.tsx
│   │   ├── InscriptionCard.tsx
│   │   ├── InscriptionActions.tsx ← sign/repay/liquidate/redeem switcher
│   │   ├── AssetInput.tsx       ← reusable asset row (type + address + amount)
│   │   └── AssetBadge.tsx       ← display asset pill
│   ├── hooks/
│   │   ├── useInscription.ts      ← read single inscription from contract
│   │   ├── useInscriptions.ts     ← read list from API (indexer-backed)
│   │   ├── useShares.ts         ← ERC1155 balance_of for current wallet
│   │   ├── useSign.ts           ← sign_inscription write
│   │   ├── useRepay.ts          ← repay write
│   │   ├── useLiquidate.ts      ← liquidate write
│   │   ├── useRedeem.ts         ← redeem write
│   │   └── useCreateInscription.ts
│   └── lib/
│       ├── stela.ts             ← typed contract instance helper
│       ├── u256.ts              ← bigint <-> u256 felt pair conversion
│       ├── address.ts           ← address formatting helpers
│       └── status.ts            ← compute InscriptionStatus from Inscription fields
```

### Provider Setup

```typescript
// src/app/providers.tsx
'use client'
import { StarknetConfig, argent, braavos, publicProvider } from '@starknet-react/core'
import { sepolia } from '@starknet-react/chains'

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <StarknetConfig
      chains={[sepolia]}
      provider={publicProvider()}
      connectors={[argent(), braavos()]}
      autoConnect
    >
      {children}
    </StarknetConfig>
  )
}
```

### Contract Read Pattern

```typescript
// src/hooks/useInscription.ts
import { useContractRead } from '@starknet-react/core'
import { abi } from '@stela/core/abi/stela.json'
import { STELA_ADDRESS } from '@stela/core'
import { parseInscription } from '../lib/stela'

export function useInscription(inscriptionId: string) {
  return useContractRead({
    address: STELA_ADDRESS.sepolia,
    abi,
    functionName: 'get_inscription',
    args: [inscriptionId],
    watch: true,
    select: (data) => parseInscription(data),
  })
}
```

### Contract Write Pattern

```typescript
// src/hooks/useSign.ts
import { useContractWrite, useAccount } from '@starknet-react/core'
import { abi } from '@stela/core/abi/stela.json'
import { STELA_ADDRESS } from '@stela/core'
import { toU256 } from '../lib/u256'

export function useSign(inscriptionId: string, percentage: bigint) {
  const { writeAsync, isPending, error } = useContractWrite({
    calls: [{
      contractAddress: STELA_ADDRESS.sepolia,
      entrypoint: 'sign_inscription',
      calldata: [
        ...toU256(BigInt(inscriptionId)),  // u256 = [low, high]
        ...toU256(percentage),
      ],
    }],
  })
  return { sign: writeAsync, isPending, error }
}
```

### Critical: u256 Handling

**This will bite you everywhere. u256 in Cairo = two felt252 values (low, high).**

```typescript
// src/lib/u256.ts
import { uint256 } from 'starknet'

// bigint → [low, high] calldata pair
export const toU256 = (n: bigint): [string, string] => {
  const { low, high } = uint256.bnToUint256(n)
  return [low.toString(), high.toString()]
}

// Contract response { low: bigint, high: bigint } → bigint
export const fromU256 = (u: { low: bigint; high: bigint }): bigint =>
  uint256.uint256ToBN(u)

// Inscription IDs come back as u256 — always convert before using as string keys
export const inscriptionIdToHex = (u: { low: bigint; high: bigint }): string =>
  '0x' + fromU256(u).toString(16).padStart(64, '0')
```

### Status Computation

```typescript
// src/lib/status.ts
import { Inscription, InscriptionStatus, MAX_BPS } from '@stela/core'

export function computeStatus(a: Inscription): InscriptionStatus {
  if (a.is_repaid) return 'repaid'
  if (a.liquidated) return 'liquidated'
  if (a.issued_debt_percentage === 0n) return 'open'

  const now = BigInt(Math.floor(Date.now() / 1000))
  const dueAt = a.signed_at + a.duration

  if (a.signed_at > 0n && now > dueAt) return 'expired'
  if (a.issued_debt_percentage === MAX_BPS) return 'filled'
  return 'partial'
}
```

### Pages: What Each Page Does

**`/` (browse):**
- Fetches open/partial inscriptions from `GET /api/inscriptions?status=open`
- Renders `InscriptionCard` grid
- Filter controls: asset type, amount range, duration

**`/create`:**
- Multi-step form: asset arrays (debt, collateral, interest), duration, deadline, multi_lender toggle
- Calls `create_inscription` on submit
- Redirects to `/inscription/[id]` on success

**`/inscription/[id]`:**
- Reads inscription state directly from contract (`useInscription`)
- Reads caller's share balance (`useShares`)
- Shows correct action based on status:
  - `open` / `partial` → sign form (percentage input for multi_lender)
  - `filled` + within window → repay button
  - `expired` → liquidate button
  - `repaid` || `liquidated` → redeem button (if shares > 0)

**`/portfolio`:**
- Fetches from `GET /api/inscriptions?address={wallet}` 
- Shows inscriptions where wallet is borrower OR lender
- Groups by: active loans, active lends, closed positions

### Environment Variables

```bash
# apps/web/.env.local
NEXT_PUBLIC_STELA_ADDRESS=0x...
NEXT_PUBLIC_NETWORK=sepolia
NEXT_PUBLIC_RPC_URL=https://starknet-sepolia.public.blastapi.io
NEXT_PUBLIC_API_URL=http://localhost:3001  # indexer API
```

---

## App: indexer

### Purpose
Stream Stela contract events from StarkNet into Postgres.
This is the only way to enumerate inscriptions for browsing/discovery.

### Stack
```
@apibara/indexer
@apibara/starknet
postgres (pg driver)
```

### Structure
```
apps/indexer/
├── src/
│   ├── indexer.ts       ← Apibara DNA stream handler
│   ├── handlers/
│   │   ├── created.ts   ← InscriptionCreated event handler
│   │   ├── signed.ts    ← InscriptionSigned event handler
│   │   ├── repaid.ts    ← InscriptionRepaid event handler
│   │   ├── liquidated.ts
│   │   └── redeemed.ts
│   ├── db/
│   │   ├── schema.sql   ← Postgres schema (run once)
│   │   └── queries.ts   ← typed pg queries
│   └── api/
│       └── server.ts    ← tiny Express API over the Postgres data
└── package.json
```

### Database Schema

```sql
-- apps/indexer/src/db/schema.sql

CREATE TABLE inscriptions (
  id                      TEXT PRIMARY KEY,     -- u256 as 0x hex
  creator                 TEXT NOT NULL,
  borrower                TEXT,
  lender                  TEXT,
  status                  TEXT NOT NULL DEFAULT 'open',
  issued_debt_percentage  BIGINT NOT NULL DEFAULT 0,
  multi_lender            BOOLEAN NOT NULL DEFAULT FALSE,
  duration                BIGINT,
  deadline                BIGINT,
  signed_at               BIGINT,
  debt_asset_count        INTEGER,
  interest_asset_count    INTEGER,
  collateral_asset_count  INTEGER,
  created_at_block        BIGINT,
  created_at_ts           BIGINT,
  updated_at_ts           BIGINT
);

CREATE TABLE inscription_assets (
  inscription_id  TEXT NOT NULL REFERENCES inscriptions(id),
  asset_role    TEXT NOT NULL,   -- 'debt' | 'interest' | 'collateral'
  asset_index   INTEGER NOT NULL,
  asset_address TEXT NOT NULL,
  asset_type    TEXT NOT NULL,
  value         TEXT,            -- stored as string (u256 too large for bigint)
  token_id      TEXT,
  PRIMARY KEY (inscription_id, asset_role, asset_index)
);

CREATE TABLE inscription_events (
  id            SERIAL PRIMARY KEY,
  inscription_id  TEXT NOT NULL,
  event_type    TEXT NOT NULL,
  tx_hash       TEXT NOT NULL,
  block_number  BIGINT NOT NULL,
  timestamp     BIGINT,
  data          JSONB
);

CREATE INDEX ON inscriptions(status);
CREATE INDEX ON inscriptions(creator);
CREATE INDEX ON inscriptions(borrower);
CREATE INDEX ON inscriptions(lender);
CREATE INDEX ON inscriptions(deadline);
```

### Indexer Core Pattern

```typescript
// apps/indexer/src/indexer.ts
import { defineIndexer } from '@apibara/indexer'
import { StarknetStream } from '@apibara/starknet'
import { STELA_ADDRESS } from '@stela/core'
import { handleCreated } from './handlers/created'
import { handleSigned } from './handlers/signed'
import { handleRepaid } from './handlers/repaid'
import { handleLiquidated } from './handlers/liquidated'

// Event selectors — compute with starknet.js selector.getSelectorFromName()
const SELECTORS = {
  InscriptionCreated:   '0x...',
  InscriptionSigned:    '0x...',
  InscriptionCancelled: '0x...',
  InscriptionRepaid:    '0x...',
  InscriptionLiquidated:'0x...',
  SharesRedeemed:     '0x...',
}

export default defineIndexer(StarknetStream)({
  streamUrl: process.env.APIBARA_STREAM_URL!,
  startingBlock: Number(process.env.START_BLOCK ?? 0),
  filter: {
    events: [
      {
        address: STELA_ADDRESS.sepolia as `0x${string}`,
        keys: Object.values(SELECTORS).map(s => [s as `0x${string}`]),
      }
    ]
  },
  async transform({ events }) {
    for (const event of events) {
      const selector = event.keys[0]
      switch (selector) {
        case SELECTORS.InscriptionCreated:    await handleCreated(event); break
        case SELECTORS.InscriptionSigned:     await handleSigned(event); break
        case SELECTORS.InscriptionRepaid:     await handleRepaid(event); break
        case SELECTORS.InscriptionLiquidated: await handleLiquidated(event); break
      }
    }
  }
})
```

### API Server

```typescript
// apps/indexer/src/api/server.ts
// Tiny Express API that the frontend queries for lists
// All writes go directly to the contract — this is read-only

import express from 'express'
import { db } from '../db/queries'

const app = express()

// GET /api/inscriptions?status=open&page=1&limit=20
app.get('/api/inscriptions', async (req, res) => {
  const { status, address, page = '1', limit = '20' } = req.query
  const inscriptions = await db.getInscriptions({
    status: status as string,
    address: address as string,
    page: Number(page),
    limit: Number(limit),
  })
  res.json(inscriptions)
})

// GET /api/inscriptions/:id
app.get('/api/inscriptions/:id', async (req, res) => {
  const inscription = await db.getInscription(req.params.id)
  if (!inscription) return res.status(404).json({ error: 'not found' })
  res.json(inscription)
})

app.listen(3001)
```

### Environment Variables

```bash
# apps/indexer/.env
DATABASE_URL=postgresql://user:pass@localhost:5432/stela
APIBARA_STREAM_URL=https://sepolia.starknet.a5a.ch
APIBARA_AUTH_TOKEN=...
START_BLOCK=0
PORT=3001
```

---

## App: bot (Liquidation Bot)

### Purpose
Call `liquidate()` on inscriptions that have expired without repayment.
Without this, lenders can never recover collateral from defaulted loans.

### Stack
```
starknet.js v6
node-cron
pg (postgres)
```

### Structure
```
apps/bot/
├── src/
│   ├── bot.ts           ← main loop
│   ├── liquidate.ts     ← starknet.js write
│   └── query.ts         ← find liquidatable inscriptions from DB
└── package.json
```

### Core Logic

```typescript
// apps/bot/src/bot.ts
import cron from 'node-cron'
import { findLiquidatable } from './query'
import { liquidate } from './liquidate'

// Run every 2 minutes
cron.schedule('*/2 * * * *', async () => {
  const now = Math.floor(Date.now() / 1000)
  
  // Query DB for inscriptions where:
  //   status = 'filled' (signed, not yet repaid/liquidated)
  //   signed_at + duration < now  (window has passed)
  const candidates = await findLiquidatable(now)
  
  for (const inscription of candidates) {
    try {
      const txHash = await liquidate(inscription.id)
      console.log(`Liquidated ${inscription.id}: ${txHash}`)
    } catch (err) {
      console.error(`Failed to liquidate ${inscription.id}:`, err)
      // Don't crash — continue to next inscription
    }
  }
})
```

```typescript
// apps/bot/src/liquidate.ts
import { Account, RpcProvider } from 'starknet'
import { STELA_ADDRESS } from '@stela/core'
import { toU256 } from './u256'

const provider = new RpcProvider({ nodeUrl: process.env.RPC_URL! })
const account = new Account(
  provider,
  process.env.BOT_ADDRESS!,
  process.env.BOT_PRIVATE_KEY!
)

export async function liquidate(inscriptionId: string): Promise<string> {
  const { transaction_hash } = await account.execute({
    contractAddress: STELA_ADDRESS.sepolia,
    entrypoint: 'liquidate',
    calldata: [...toU256(BigInt(inscriptionId))],
  })
  
  await provider.waitForTransaction(transaction_hash)
  return transaction_hash
}
```

```typescript
// apps/bot/src/query.ts
import { pool } from './db'

export async function findLiquidatable(nowSeconds: number) {
  const result = await pool.query(`
    SELECT id
    FROM inscriptions
    WHERE status = 'filled'
      AND signed_at IS NOT NULL
      AND (signed_at + duration) < $1
    ORDER BY (signed_at + duration) ASC
    LIMIT 50
  `, [nowSeconds])
  
  return result.rows
}
```

### Environment Variables

```bash
# apps/bot/.env
DATABASE_URL=postgresql://user:pass@localhost:5432/stela
RPC_URL=https://starknet-sepolia.public.blastapi.io
BOT_ADDRESS=0x...          ← funded StarkNet wallet address
BOT_PRIVATE_KEY=0x...      ← KEEP SECRET, never commit
NETWORK=sepolia
```

**CRITICAL:** The bot wallet must hold enough ETH to pay gas for liquidation calls.
Never commit `BOT_PRIVATE_KEY` to git. Use environment variables or a secrets manager.

---

## Build Order

Build in this sequence. Each step depends on the previous.

**1. Schema + Postgres**
Run `schema.sql` to create tables. Verify connection.

**2. Indexer**
Get events flowing into Postgres before touching the frontend.
Verify `inscriptions` table is populating. Check event selectors are correct.

**3. Bot**
Wire up bot with a funded test wallet on sepolia.
Verify it finds liquidatable inscriptions and sends transactions.

**4. Frontend**
By now the hard problems are solved. Build pages against real data.

---

## Shared Utilities (copy into each app that needs them)

Both `web/` and `bot/` need the same `toU256` / `fromU256` helpers.
Define them in `packages/core/src/u256.ts` and import from `@stela/core`.

```typescript
// packages/core/src/u256.ts
import { uint256 } from 'starknet'

export const toU256 = (n: bigint): [string, string] => {
  const { low, high } = uint256.bnToUint256(n)
  return [low.toString(), high.toString()]
}

export const fromU256 = (low: bigint, high: bigint): bigint =>
  uint256.uint256ToBN({ low, high })
```

---

## StarkNet-Specific Gotchas

**u256 is two felts:** Every inscription ID, token amount, share count, and percentage
is a u256 in Cairo. On the JS side it arrives as `{ low: bigint, high: bigint }`.
Always use `toU256` / `fromU256`. Forgetting this causes silent wrong values.

**Contract addresses are felt252:** 32-byte hex, left-padded with zeros.
Use `addAddressPadding` from starknet.js before comparing or displaying.

**Event selectors:** Compute with `selector.getSelectorFromName('InscriptionCreated')`.
Don't hardcode unless you've verified them against the actual ABI.

**Calldata arrays:** When passing `Array<Asset>` to `create_inscription`, Cairo arrays
serialize as `[length, item0_field0, item0_field1, ..., itemN_fieldN]`.
starknet.js handles this if you use the ABI encoder. If building calldata manually,
prefix with the array length as a felt.

**Block timestamps vs JS timestamps:** Cairo timestamps are u64 seconds.
JS `Date.now()` is milliseconds. Always `Math.floor(Date.now() / 1000)` when comparing.

**Pending transactions:** After a write, `useWaitForTransaction` before assuming
state has changed. StarkNet finality takes longer than other chains.

---

## InscriptionParams Struct (for create_inscription calldata)

```
InscriptionParams {
  is_borrow: bool
  debt_assets: Array<Asset>        ← Cairo array: [len, ...items]
  interest_assets: Array<Asset>
  collateral_assets: Array<Asset>
  duration: u64
  deadline: u64
  multi_lender: bool
}

Asset {
  asset: ContractAddress           ← felt252
  asset_type: AssetType            ← enum: 0=ERC20, 1=ERC721, 2=ERC1155, 3=ERC4626
  value: u256                      ← [low, high]
  token_id: u256                   ← [low, high]
}
```

---

## What Goes Where (Decision Rule)

| Action | Goes where |
|--------|-----------|
| Read inscription state | Direct contract read (`useContractRead`) |
| Read share balance | Direct contract read (`erc1155.balance_of`) |
| Browse/list inscriptions | API backed by indexer DB |
| Portfolio / history | API backed by indexer DB |
| Create, sign, repay, liquidate, redeem, cancel | Direct contract write via user wallet |
| Trigger liquidation automatically | Bot wallet |

Never proxy writes through the backend. Users sign directly with their wallet.
The backend is read-only except for the bot's liquidation calls.

---

## After Creating/Updating Code

```bash
pnpm lint          # lint all apps
pnpm build         # build all apps
pnpm sync-abi      # if contracts changed
```

TypeScript strict mode is non-negotiable. No `any`. No `ts-ignore` without a comment explaining why.

---

## Genesis NFT System

### StelaGenesis (`src/genesis.cairo`)

ERC721 mint contract. 300 max supply, sequential IDs 1-300. Constructor mints 50 NFTs (IDs 1-50) to treasury. Payment in STRK (1,000 STRK per mint, 18 decimals). Per-wallet cap of 5. Starts with minting disabled; owner calls `set_mint_enabled(true)` to open.

**Interface (`IStelaGenesis`):**
- `mint()` / `mint_batch(quantity)` — public mint (max 5 per wallet)
- `total_minted()`, `max_supply()`, `mint_price()`, `mint_enabled()`, `payment_token()`, `mint_recipient()` — views
- `set_mint_price()`, `set_mint_enabled()`, `set_mint_recipient()`, `set_base_uri()` — admin (owner only)
- `admin_mint(to, quantity)` — owner mint without payment (reserves/airdrops)
- `pause()` / `unpause()` — emergency controls

**Events:** `Minted(token_id, minter, price)`

### Fee Model — Treasury-Direct with NFT Discounts

Fees are transferred directly to a treasury address via simple `transfer()`. There is no FeeVault contract. Genesis NFT holders receive fee **discounts** rather than fee revenue.

### Pro-Rata Interest on Early Repayment

Interest is pro-rated by elapsed time: `ceil(full_interest * elapsed / duration)`. Rounds UP (ceiling) to protect lenders. Swaps (duration=0) always charge full interest. See `src/utils/share_math.cairo` for `pro_rata_interest()` and `div_ceil()`.

### Fee Constants in `src/stela.cairo`

All fees charged at settle only. No redeem fee. No share dilution (`inscription_fee` removed).

```
Loans (duration > 0): RELAYER_BPS=5 + SETTLE_TREASURY_BASE=20 = 25 BPS (0.25%)
Swaps (duration = 0): RELAYER_BPS=5 + SWAP_TREASURY_BASE=10  = 15 BPS (0.15%)
Redeem: 0 BPS
Liquidate: 0 BPS
```

Fee floors after NFT discount: settle treasury min 10 BPS, swap treasury min 5 BPS.

### NFT Discount Model

Genesis NFT holders get fee discounts on settle (treasury portion only):
- **Base discount**: 15% (holding 1+ NFT)
- **Volume tiers**: +5% per tier (7 tiers from $10K to $1M settled volume)
- **Per-extra-NFT bonus**: +2% per additional NFT held
- **Cap**: 50% maximum discount

The relayer portion (5 BPS) is never discounted. Discounts apply only to the treasury portion.

**Admin functions on Stela contract:**
- `set_treasury(treasury)` — set treasury address
- `get_treasury()` — read current treasury address
- `set_genesis_contract(genesis)` — set Genesis NFT contract for discount checks
- `get_genesis_contract()` — read Genesis NFT contract address
- `get_volume_settled(address)` — view settled volume for an address

LIQUIDATE: no extra fee.

### Deployment Order

1. Deploy **StelaGenesis** (owner, STRK token address, mint recipient, treasury, base URI) — 50 NFTs auto-mint to treasury
2. Call `stela.set_treasury(treasury_address)` on the Stela contract
3. Call `stela.set_genesis_contract(genesis_address)` on the Stela contract
4. Call `genesis.set_mint_enabled(true)` to open minting
