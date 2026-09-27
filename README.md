# AvengeHook — MEV Protection for Uniswap V4

> **An on-chain MEV protection hook that fights back. When a swap executes far away from the oracle price, AvengeHook captures part of the arbitrage and donates it to liquidity providers — turning MEV extraction into LP revenue.**

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4-FF007A.svg)](https://uniswap.org/)
[![Pyth Network](https://img.shields.io/badge/Oracle-Pyth%20Network-6C5CE7.svg)](https://pyth.network/)
[![Rust](https://img.shields.io/badge/Tooling-Rust-CE422B.svg)](https://www.rust-lang.org/)
[![Arbitrum](https://img.shields.io/badge/Deployed-Arbitrum%20Sepolia-28A0F0.svg)](https://arbitrum.io/)
[![Tests](https://img.shields.io/badge/Solidity%20tests-136%20%2F%20136-42ba76.svg)](./detox-hook/packages/foundry)

> **Naming in this repo:** the product is **AvengeHook**, the hook contract is [`DetoxHook.sol`](./detox-hook/packages/foundry/src/DetoxHook.sol), and the Rust CLI is **`detox-rs`** in [`avenge-rs/`](./avenge-rs).

---

## The Problem

MEV bots extract **$1B+ annually** from Uniswap pools. When a pool becomes mispriced relative to global markets, arbitrageurs:

- **Drain LP reserves** through atomic arbitrage cycles
- **Leave LPs with impermanent loss** worse than simply holding
- **Extract value** that should belong to liquidity providers
- **Create unfair pricing** that hurts regular traders

Traditional MEV protection is off-chain (keepers, private mempools). AvengeHook does it **on-chain**, inside `beforeSwap`, using Pyth's real-time prices with confidence intervals.

---

## Our Solution

```
Swap arrives (exact input)
    │
    ▼
┌───────────────────────────────┐
│ 1. Read Pyth prices           │  input + output currency, with confidence
│    staleness guard            │  stale/invalid → pass through untouched
└────────┬──────────────────────┘
         ▼
┌───────────────────────────────┐
│ 2. Compare live pool price    │  pool price = currency1 per currency0 (slot0)
│    with market price          │  market price = p(currency0) / p(currency1)
└────────┬──────────────────────┘
         ▼
   outside Pyth confidence band
   AND deviation ≥ 2% ?
    │                │
   NO               YES
    │                │
    ▼                ▼
 Pass through   ┌──────────────────────────────────────────┐
 unchanged      │ 3. opportunity = amountIn × deviation    │
                │    hookShare  = opportunity × 70%        │
                │                                       │
                │ 4. take(hookShare) from the pool        │
                │    donate(80% of hookShare) → LPs       │  feeGrowthGlobal
                │    keep 20% of hookShare in the hook    │  withdrawable by owner
                │                                       │
                │ 5. beforeSwap fee override = 0.30%      │  only on dynamic-fee pools
                │    (base fee stays 0.05%)               │
                │                                       │
                │ Safety rails: capture ≤ 50% of the      │  MAX_CAPTURE_BPS
                │ swap input; never interferes with       │
                │ exact-output swaps or empty pools       │
                └──────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Why |
|----------|-----|
| **Confidence bands** | The pool must sit *outside* Pyth's confidence interval — oracle noise never triggers a capture |
| **2% deviation threshold** | `ARBITRAGE_THRESHOLD = 200 bps`; ordinary slippage passes through untouched |
| **70/30 split (`rhoBps = 7000`)** | The hook takes 70% of the opportunity, the arbitrageur keeps 30%, so price correction still pays for itself (see [Game Theory](#game-theory)) |
| **80/20 of the captured share** | `LP_SHARE = 80`: 80% of what the hook captures goes to LPs via `donate()`, 20% accrues to the hook/owner |
| **Capture cap** | `MAX_CAPTURE_BPS = 5000` — never take more than 50% of the swap's input |
| **Dynamic fee override** | `OVERRIDE_FEE_FLAG` charges 0.30% on an arb swap instead of the 0.05% base fee — *dynamic-fee pools only* (see [Fee override scope](#fee-override-scope)) |
| **`poolManager.donate()`** | Updates `feeGrowthGlobal`, so captured value is distributed proportionally to in-range LPs |
| **No-op `_beforeDonate`** | The address is mined with `BEFORE_DONATE_FLAG`; `BaseHook`'s default implementation would revert and break third-party `donate()` calls |
| **Pyth pull oracle** | Prices are read inside the same transaction — the hook never acts on cached keeper data (stale store → fail-open) |
| **Fail-open** | Any oracle failure, missing liquidity, or over-sized capture degrades to "do nothing" rather than reverting the swap |

---

## Project Structure

```
ARBITRAGEBOT/
├── README.md                              # This file
├── .gitignore
│
├── avenge-rs/                             # Rust CLI (crate: detox-rs)
│   ├── Cargo.toml                         # ethers 2.0, tokio, eyre, serde
│   ├── .env.example                       # Configuration template
│   └── src/
│       ├── main.rs                        # CLI entry point (16 commands)
│       ├── config.rs                      # env config + FORGE_DIR / POOL_ID / USDC
│       ├── hook.rs                        # abigen!() bindings incl. calculateArbitrageOpportunity
│       ├── monitor.rs                     # real-time event monitoring (6 events)
│       ├── deploy.rs                      # shells out to forge script
│       ├── pyth.rs                        # direct Pyth price reads + normalization tests
│       ├── keeper.rs                      # Hermes → store replay loop (keeper) + tests
│       └── pyth_live.rs                   # keyless on-chain reader (live-prices) + tests
│
└── detox-hook/
    └── packages/foundry/                  # Foundry project
        ├── foundry.toml                   # solc 0.8.26, cancun, via_ir, 50 runs
        ├── remappings.txt                 # import path aliases
        ├── src/
        │   ├── DetoxHook.sol              # main hook (594 lines)
        │   ├── PoolRegistry.sol           # pool registry helper
        │   ├── SwapRouter.sol             # test swap router
        │   ├── SwapRouterFixed.sol
        │   └── libraries/
        │       ├── ArbitrageLib.sol       # price convention + arb math (265 lines)
        │       ├── OracleLib.sol          # Pyth read, staleness, normalization
        │       ├── HookLibrary.sol        # slot0 / liquidity / price helpers
        │       └── PythLibrary.sol        # Pyth interfaces + MockPyth
        ├── test/                          # 13 suites, 136 tests
        │   ├── DetoxHookCapture.t.sol     # end-to-end capture flow
        │   ├── ArbitrageLib.t.sol         # pure math unit tests
        │   ├── OracleLib.t.sol            # oracle normalization tests
        │   ├── DetoxHook.t.sol / Wave1 / Wave2
        │   ├── DetoxHookArbitrumSepoliaFork.t.sol   # live fork tests
        │   └── ...
        └── script/
            ├── DeployDetoxHook.s.sol              # CREATE2 deployment
            ├── DeployDetoxHookComplete.s.sol      # deploy + fund + pools + liquidity
            ├── InitializePools.s.sol              # dynamic-fee pools + base fee
            ├── InitializePoolsWithHook.s.sol      # pools for an existing hook
            └── FundDetoxHook.s.sol                # hook funding
```

> `detox-hook/packages/foundry/lib/` (v4-core, forge-std, OZ, Pyth SDK, …) is **gitignored** — run `forge install` in Quick Start below.

---

## Smart Contract Architecture

### `DetoxHook.sol`

Inherits Uniswap V4's `BaseHook` (`beforeSwap` + `beforeSwapReturnsDelta` + `beforeDonate`):

```solidity
contract DetoxHook is BaseHook {
    // Tunables
    uint256 public constant ARBITRAGE_THRESHOLD = 200; // 2% deviation before interfering
    uint256 public constant CAPTURE_RATE        = 70;  // % of opportunity taken by the hook
    uint256 public constant LP_SHARE            = 80;  // % of the captured share donated to LPs
    uint256 public constant MAX_CAPTURE_BPS     = 5000; // capture never exceeds 50% of input
    uint24  private constant ARB_FEE_PIPS       = 3000; // 0.30% LP fee on detected arbs
    uint24  private constant NORMAL_FEE_PIPS    = 500;  // 0.05% base fee for dynamic pools

    // State
    uint256 public rhoBps;                 // = CAPTURE_RATE * 100 = 7000 (owner-tunable)
    uint256 public stalenessThreshold;     // owner-tunable (live: 60 s, keeper-fed)
    address public owner;
    IPyth   public pythOracle;
    mapping(Currency => bytes32) public pythPriceIds;
    mapping(PoolId => mapping(Currency => uint256)) public accumulatedTokens;

    // Hook callbacks
    function _beforeSwap(...)  internal override returns (bytes4, BeforeSwapDelta, uint24);
    function _beforeDonate(...) internal pure override returns (bytes4);  // no-op
    function getHookPermissions() public pure override returns (Hooks.Permissions);

    // Views
    function getParameters() external view returns (uint256 rho, uint256 staleness, uint256 lpDonateBps);
    function getAccumulatedTokens(PoolId, Currency) external view returns (uint256);
    function getOraclePrice(Currency) external view returns (uint256 price, bool valid, uint256 publishTime);
    function getOraclePriceWithConfidence(Currency) external view returns (uint256, uint256, bool, uint256);
    function calculateArbitrageOpportunity(PoolKey calldata, SwapParams calldata)
        external view returns (uint256 arbitrageOpp, uint256 hookShare, bool shouldInterfere, bool outsideBand);
    function normalFeePips() external pure returns (uint24);   // 500
    function arbFeePips()    external pure returns (uint24);   // 3000

    // Owner
    function updateParameters(uint256 rhoBps, uint256 stalenessThreshold) external onlyOwner;
    function setPriceId(Currency, bytes32) external onlyOwner;
    function setDynamicLPFee(PoolKey calldata, uint24) external onlyOwner;
    function withdrawAccumulatedETH(PoolId, uint256, address payable) external onlyOwner;
    function withdrawAccumulatedERC20(PoolId, Currency, uint256, address) external onlyOwner;
}
```

**Safety rails in `_beforeSwap`** (each returns "pass through" instead of reverting): exact-output swaps, invalid/stale oracle prices, zero pool price, no interference below the 2% threshold, capture clamped to `MAX_CAPTURE_BPS`, capture too large for `int128`, and pools with zero liquidity (because `donate()` reverts on an empty pool).

**Settlement accounting** (verified by `DetoxHookCapture.t.sol`): `take(hookShare)` + `donate(lp)` + `settle(lp)` + the `afterSwap` hook delta nets to zero inside the unlock — the hook keeps only `hookKept` (20% of the capture), LPs receive the donated 80%.

### `ArbitrageLib.sol`

Price convention and the decision math:

```solidity
// Pool price   = currency1 per currency0  (from slot0 sqrtPriceX96)
// Market price = p(currency0) / p(currency1)   (oracle USD prices, ratio only)
//
// zeroForOne (selling currency0):  pool over-pays when poolPrice >  market
// !zeroForOne (selling currency1): pool over-pays when poolPrice <  market
//
// opportunity (denominated in the input currency, measured against the
// conservative side of the confidence interval):
//   zeroForOne : amountIn * (poolPrice - marketUpper) / marketUpper
//   other      : amountIn * (marketLower - poolPrice) / poolPrice

shouldInterfere =
       pool price is outside the confidence band
    && pool pays the swapper more than the market
    && |poolPrice - marketPrice| / marketPrice >= 200 bps;

hookShare = opportunity * rhoBps / 10000;   // rhoBps = 7000 by default
```

### `OracleLib.sol`

```solidity
(PythStructs.Price memory p, bool success) = safePythCall(pythOracle, priceId);
if (!success)                    return (0, 0, false);            // never reverts the swap
if (block.timestamp - p.publishTime > stalenessThreshold) return (0, 0, false);
price      = normalize(p.price, p.expo);   // → 1e8 PRICE_PRECISION
confidence = normalize(p.conf,   p.expo);
```

### Fee override scope

Uniswap V4 only honors a `beforeSwap` fee override when `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`). Therefore:

- Pools created by `InitializePools.s.sol`, `InitializePoolsWithHook.s.sol` and `DeployDetoxHookComplete.s.sol` use `DYNAMIC_FEE_FLAG` and call `hook.setDynamicLPFee(key, 500)` right after `initialize()` (dynamic pools otherwise start at a **0%** LP fee).
- On static-fee pools the 0.30% arb fee is silently ignored — the capture still happens, only the fee override does not.
- `ARBITRAGE_THRESHOLD`, `rhoBps` and the capture itself are unaffected by this.

---

## Rust CLI Tooling (`avenge-rs`)

`detox-rs` monitors, manages and deploys the hook.

### Commands

| Command | Description | Requires Key |
|---------|-------------|:------------:|
| `monitor` | Watch all 6 hook events in real time (polls every 2s) | No |
| `prices` | Fetch ETH / USDC / BTC prices straight from Pyth | No |
| `live-prices` | Keyless on-chain Pyth reader: age, freshness vs live staleness, RPC latency (HTTP/WS auto-detect) | No |
| `keeper [interval] [maxPolls]` | Hermes → store replay loop: fetches signed payloads and publishes them every 5 s (default) | Yes (`PYTH_API_KEY`) |
| `state` | Full on-chain state: owner, params, pool ID, accumulators, price IDs | No |
| `params` | `rhoBps`, `stalenessThreshold`, `lpDonateBps` | No |
| `oracle` | Oracle prices + confidence as the *hook* sees them | No |
| `permissions` | Display all 14 permission flags | No |
| `simulate [amount] [zeroForOne]` | Calls `calculateArbitrageOpportunity(poolKey, swapParams)` on-chain | No |
| `update-params <rhoBps> <staleness>` | Change capture share and oracle staleness | Yes |
| `set-price-id <currency> <priceId>` | Point a currency at a Pyth feed | Yes |
| `withdraw <poolId> <currency> <amount> <recipient>` | Withdraw accumulated ETH/ERC20 | Yes |
| `deploy` | Deploy via Forge to any chain (needs `DEPLOYMENT_KEY`) | Yes |
| `deploy-local` | Deploy to local Anvil | No |
| `test` | Run the Forge test suite | No |
| `help` | Usage text | No |

### Usage Examples

```bash
# Read current state
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc \
HOOK_ADDRESS=0xf53c43858D62a1765480508f3bE7481e883380A8 \
cargo run -- state

# Monitor events in real time
cargo run -- monitor

# Oracle prices as the hook sees them
cargo run -- oracle

# Keeper: replay fresh Hermes payloads into the Pyth store (needs PYTH_API_KEY)
cargo run -- keeper          # every 5s, forever
cargo run -- keeper 5 10     # 10 polls then exit

# Simulate a 1.0 ETH swap selling currency0 (zeroForOne = true)
cargo run -- simulate 1.0 true

# Simulate selling 100 USDC (zeroForOne = false)
cargo run -- simulate 100 false

# Update parameters (owner only)
DEPLOYMENT_KEY=0x... cargo run -- update-params 7000 60

# Set Pyth price ID for USDC
cargo run -- set-price-id 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d \
  0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a

# Withdraw accumulated ETH from a pool
cargo run -- withdraw \
  0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b \
  0x0000000000000000000000000000000000000000 \
  1000000000000000000 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Deploy to local Anvil, then monitor
anvil &
cargo run -- deploy-local
RPC_URL=http://127.0.0.1:8545 HOOK_ADDRESS=<deployed> cargo run -- monitor
```

### Architecture

```
main.rs        CLI arg parsing, command dispatch
 ├── config.rs Loads .env: RPC_URL, HOOK_ADDRESS, PYTH_ADDRESS, CHAIN_ID,
 │              POOL_ID, USDC_ADDRESS, FORGE_DIR + simulate overrides
 ├── hook.rs    ethers-rs abigen!() bindings — every view + owner function,
 │              including calculateArbitrageOpportunity(PoolKey, SwapParams)
 ├── monitor.rs Block-polling loop (2s) decoding all 6 events by topic0
 ├── deploy.rs  Shells out to `forge script`, parses the deployed address
 ├── keeper.rs  Hermes API → signed PNAU payload → updatePriceFeeds replay
 └── pyth.rs    Direct Pyth reads + expo → 1e8 normalization (unit-tested)
```

---

## Events

All six events are emitted and decoded by `monitor.rs`:

| Event | Indexed Fields | Data Fields |
|-------|----------------|-------------|
| `ArbitrageCaptured` | poolId, currency | hookShare, arbitrageOpportunity, zeroForOne |
| `DonateToLPs` | poolId, currency | amount, hookKept |
| `ParametersUpdated` | — | oldRhoBps, newRhoBps, oldStaleness, newStaleness |
| `PriceIdUpdated` | currency | oldPriceId, newPriceId |
| `ETHWithdrawn` | poolId, recipient | amount |
| `ERC20Withdrawn` | poolId, currency | amount, recipient |

### Event Topic Hashes (keccak256, verified against `cast sig-event`)

```
ArbitrageCaptured:  0x815f5204730edec69803e4e5f169e34a0d37eb4217f2d04b104edab0d2496989
ParametersUpdated:  0xbca959adb5aa52aaea5a17838313a61bebf160bf6064e31593c79c8432c79fea
DonateToLPs:        0xb9dc18a4dbc9133971c8e3772c1e337989a9f11405f5ed603caf2ba59cad459b
PriceIdUpdated:     0x614ad967403eca3c4a400b170d2fb8397a2eeffdad616ec761d3e492545f09e2
ETHWithdrawn:       0xe85193b00649d7c1275a569a5b49ce0a70d8c33fe2d4dfcb358670aa392e564a
ERC20Withdrawn:     0x7f7a3c8adc2282c3f39a78be1ad8844fb24545a77dd1e1179c41d11e8a6da302
```

---

## Testing

### Solidity — 136 / 136 passing (13 suites)

```bash
cd detox-hook/packages/foundry
forge test
```

| Suite | Tests | What it verifies |
|-------|:-----:|------------------|
| `ArbitrageLib.t.sol` | 21 | Price convention, confidence bounds, opportunity math, threshold |
| `OracleLib.t.sol` | 23 | Pyth normalization, staleness, invalid/zero price handling |
| `DetoxHookWave1.t.sol` | 13 | Deployment, permissions, params, swaps, accumulators |
| `DetoxHook.t.sol` | 10 | Parameters, permissions, tracking, owner functions |
| `DetoxHookWave2.t.sol` | 10 | Arbitrage detection both directions, thresholds, param updates |
| `DetoxHookCapture.t.sol` | 8 | **End-to-end capture**: take → donate → keep, fee override, caps, stale oracle, external `donate()` |
| `DetoxHookLocal.t.sol` | 9 | Local Anvil flows |
| `DetoxHookLocalSimple.t.sol` | 1 | Simplified local flow |
| `SwapRouter.t.sol` | 8 | Test router integration |
| `DeployDetoxHookScript.t.sol` | 11 | CREATE2 mining, script helpers, full deploy workflow |
| `HookMinerTest.t.sol` | 4 | Hook address flag mining |
| `DetoxHookLive.t.sol` | 7 | Live-address introspection |
| `DetoxHookArbitrumSepoliaFork.t.sol` | 11 | Fork of Arbitrum Sepolia: real swaps, liquidity, Pyth reads (**needs internet**) |

The fork suite is the only one that touches the network — it hardcodes `https://sepolia-rollup.arbitrum.io/rpc`; everything else runs offline.

### Rust — 14 / 14 passing

```bash
cd avenge-rs && cargo test
```

Pyth `expo` → 1e8 normalization (`test_normalize_*`), plus `pyth_live` reader tests: feed-ID stability, f64 math across mixed exponents, `1e8` scaling, negative-mantissa rejection, and the freshness window — plus `keeper` tests: Hermes response decoding, `PNAU` magic validation, and feed-price parsing.

---

## Configuration

### Contract Parameters

| Parameter | Value | Meaning |
|-----------|------:|---------|
| `ARBITRAGE_THRESHOLD` | `200` bps (2%) | Minimum pool-vs-market deviation before interfering |
| `CAPTURE_RATE` / `rhoBps` | `70`% / `7000` | Share of the opportunity captured by the hook (owner-tunable) |
| `LP_SHARE` / `LP_DONATE_BPS` | `80`% / `8000` | Share of the capture donated to LPs via `donate()` |
| `MAX_CAPTURE_BPS` | `5000` (50%) | Hard cap: capture can never exceed half of the swap input |
| `ARB_FEE_PIPS` | `3000` (0.30%) | LP fee charged on a detected arb (dynamic pools only) |
| `NORMAL_FEE_PIPS` | `500` (0.05%) | Base LP fee for dynamic pools |
| `stalenessThreshold` | owner-set; live `60` s (keeper-fed) | Oracle freshness limit (owner-tunable) |
| `BASIS_POINTS` | `10000` | 100% |

> Fee units: Uniswap V4 LP fees are **pips** — `1e6 = 100%`. So `3000` is **0.30%**, not 30%.

### Environment Variables

```bash
# avenge-rs/.env
RPC_URL=http://127.0.0.1:8545                             # Required
HOOK_ADDRESS=0xf53c43858D62a1765480508f3bE7481e883380A8   # Required
PYTH_ADDRESS=0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF   # Optional (defaults to Arbitrum Sepolia)
CHAIN_ID=421614                                           # Default: Arbitrum Sepolia
FORGE_DIR=./detox-hook/packages/foundry                   # Auto-detected
DEPLOYMENT_KEY=0x...                                      # Owner commands + deploy + keeper sends
PYTH_API_KEY=...                                          # keeper only (free trial: pythdata.app)

# Pool context used by `state` and `simulate`
POOL_ID=0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b
USDC_ADDRESS=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d

# Pool key quoted by `simulate` (defaults match POOL_ID above)
CURRENCY0=0x0000000000000000000000000000000000000000
CURRENCY1=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
POOL_FEE=8388608  # dynamic-fee pool
TICK_SPACING=30
CURRENCY0_DECIMALS=18
CURRENCY1_DECIMALS=6
```

---

## Game Theory

```
┌──────────────────────────────────────────────────────────┐
│                      VALUE FLOW                          │
├──────────────────────────────────────────────────────────┤
│                                                          │
│   Arbitrageur ── swap ──▶ Pool                           │
│        │                    │                            │
│        ▼                    ▼                            │
│   keeps 30%          hook captures 70% of opportunity    │
│   of opportunity            │                            │
│                             ├─ 80% of that → donate()    │
│                             │    (56% of the whole       │
│                             │     opportunity → LPs)     │
│                             └─ 20% of that → hook        │
│                                  (14% → owner treasury)  │
│                                                          │
│   + pays 0.30% LP fee on the arb swap (dynamic pools)    │
└──────────────────────────────────────────────────────────┘
```

### Why This Works

- **Arbitrageurs still profit** — at the 2% intervention threshold the arb nets `30% × 2% − 0.30% = +0.30%`, so they keep correcting prices instead of abandoning the pool.
- **LPs win** — 56% of every detected opportunity lands in `feeGrowthGlobal`, paid to in-range LPs (an extra `donate()` on top of normal swap fees).
- **The protocol earns** — the remaining 14% accrues in the hook and is withdrawable by the owner.
- **No arms race** — detection runs on-chain in the same block the mispricing appears.
- **Confidence bands** — normal swappers are never taxed for ordinary volatility.

---

## Live Deployment

**Arbitrum Sepolia:**

| Component | Address / ID | Notes |
|-----------|--------------|-------|
| **AvengeHook hook** | [`0xf53c43858D62a1765480508f3bE7481e883380A8`](https://arbitrum-sepolia.blockscout.com/address/0xf53c43858D62a1765480508f3bE7481e883380A8) | Deployed, verified, owner `0x767166724ec61042ea01c43278b94471C950B824`, permissions `beforeSwap`/`beforeSwapReturnDelta`/`beforeDonate` |
| **Pool 1** | `0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b` | ETH/USDC, **dynamic fee** (`8388608`, base `500` = 0.05%), tickSpacing **30**, initialized at **2500 USDC/ETH**, range −198690…−197490 |
| **Pool 2** | `0x19bfceedc254ba74b1eed66e2d88551be735cca9c219a2627fb643fa83bb6d43` | ETH/USDC, **dynamic fee** (`8388608`, base `500` = 0.05%), tickSpacing **120**, initialized at **2600 USDC/ETH** |
| **PoolManager** | [`0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`](https://arbitrum-sepolia.blockscout.com/address/0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317) | Uniswap v4 |
| **USDC (currency1)** | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://arbitrum-sepolia.blockscout.com/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) | 6 decimals |
| **Pyth contract** | `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF` | ETH/USD + USDC/USD feeds |
| **PoolSwapTest** | [`0xf3A39C86dbd13C45365E57FB90fe413371F65AF8`](https://arbitrum-sepolia.blockscout.com/address/0xf3A39C86dbd13C45365E57FB90fe413371F65AF8) | Verified; `swap` selector `0x2229d0b4` |

**Deployment verified end-to-end (2026-09-27):**

- Fresh hook build: full parameter getters (`rhoBps` 7000, `lpDonateBps` 8000, `arbFeePips` 3000, `normalFeePips` 500) and the `beforeDonate` flag, so third-party `poolManager.donate()` works.
- `stalenessThreshold` is back to **60 s** (owner tx `0xde0993ab…66b0`). Earlier the same day it had been widened to 30 d (`2592000` s, tx `0x7d8bb35c…`) when Hermes went key-only in the Pyth Core upgrade and no keeper was running — a 60 s window then kept both feeds `valid: false` and the hook permanently fail-open. With the Hermes keeper live, `oracle` reports `valid: true` for both feeds within seconds of publication; see [Price feeding](#price-feeding-hermes-keeper--verified-keyless-replay). If the keeper stops (or the trial key expires), prices cross 60 s and the hook fails open, by design.
- Live interference capture: tx [`0x85dd8e54…61490`](https://arbitrum-sepolia.blockscout.com/tx/0x85dd8e54fa2078b35fb8b0588f4ae49729ec30cccdb66c5179b1d09a96f61490) swapped 1 USDC → the hook detected the band deviation, emitted the capture event (`hookShare = 55119`, `opportunity = 78742`, exactly matching `simulate`), donated to LPs, applied the 0.30% override fee, and retained 11 024 units for the owner (`getAccumulatedTokens > 0`).
- Both pools hold liquidity (1.3e12 in the active range) and return the exact initialization prices through `slot0`.

---

## Price feeding (hermes keeper + verified keyless replay)

Since the Pyth Core upgrade (2026-08-26) Hermes requires an API key; a
free trial at [Pyth Terminal](https://pythdata.app) is enough. Pyth
payloads are **chain-agnostic within a contract generation** — every Core
contract was upgraded in place that day, so a payload issued anywhere
verifies on our Sepolia store.

### Primary path: `keeper` (measured)

`cargo run -- keeper` polls Hermes for ETH/USD + USDC/USD every 5 s,
decodes the signed `PNAU` payload from `binary.data`, skips it unless it
is newer than the store, then publishes with `getUpdateFee` +
`updatePriceFeeds(bytes[])` (explicit 500k gas limit). Sustained run
(2026-09-27, 8/8 and 3/3 polls status 1):

| Metric | Measured |
|---|---|
| Payload age at fetch | **0–2 s** |
| End-to-end freshness (publish → readable by the hook) | **≤ ~5 s** |
| Update fee | **20 wei** per poll |
| Skips | only when Hermes has nothing newer than the store |

That sits far inside the live **60 s** `stalenessThreshold` — comfortably
under the ~1–2 min the setup promises. Two caveats: the trial key expires
after 14 days (grab a fresh one at pythdata.app and update
`PYTH_API_KEY`), and if the keeper stops, the hook fails open 60 s later
by design.

### Keyless fallback: replay others' txs (verified)

With no API key at all, calldata replay still works: scrape the `bytes[]`
payload of any live `updatePriceFeeds` /
`updatePriceFeedsIfNecessary` transaction on a busy chain (Ethereum
mainnet, Base) and replay it into our Sepolia store with
`updatePriceFeeds(bytes[])`. The attached fee is **10–80 wei**; without
it the call reverts `InsufficientFee()` — with it, every replay has
succeeded.

**Verified replays (2026-09-27, all status 1):**

| Source payload | Replay tx | Result |
|---|---|---|
| mainnet USDC | `0xf20a752c…7fe6` | 13.3 d → ~1 h old |
| mainnet ETH | `0x47afa57a…4031` | 2 d → ~6 h old |
| mainnet USDC (freshest) | `0x1d880c3d…47cb` | → ~11 min old |
| Base batch ETH+USDC | `0xc5e6dc9f…67e0` | → ~59 min old |
| Base batch ETH+USDC | `0x368355de…f674` | → **84 s old** |

The store **verifies payload integrity** — a modified price with a valid
structure reverts `InvalidUpdateData()`, so only genuine attested data
can ever be published.

**Source ranking (measured, keyless):** Base (`0xbC16…272F5`, free RPC
`mainnet.base.org`) is best — 2 s blocks, batch payloads carrying ETH and
USDC together: ~110 s … 60 min between pushes (**avg ~28 min**). Ethereum
mainnet USDC averages ~45 min; mainnet ETH pushes roughly once per 9 h;
Arbitrum/OP/Polygon push irregularly or not at all — all consistent with
the documented **1-hour heartbeat / 1 % deviation** push-feed rules. So
the keyless path alone holds ≤ ~60 min, **not** ≤2 min; the keeper above
is what delivers the sub-minute window. Reading (not pushing) is covered
by `live-prices`, which needs no API key at all.

---

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- [Rust](https://rustup.rs/) — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`

### 1. Clone & install libraries

```bash
git clone https://github.com/Yash-arch-ui/AvengeHook.git
cd AvengeHook

# lib/ is gitignored — pull the Solidity dependencies
cd detox-hook/packages/foundry
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge install gnsps/solidity-bytes-utils
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install pyth-network/pyth-sdk-solidity
cd ../../..
```

### 2. Run the tests

```bash
cd detox-hook/packages/foundry
forge test                 # 136/136 (fork suite needs internet access)

cd ../../avenge-rs
cp .env.example .env
cargo test                 # 14/14
```

### 3. Deploy locally

```bash
anvil &                    # Terminal 1
cd avenge-rs
cargo run -- deploy-local  # Terminal 2
```

### 4. Monitor and quote

```bash
RPC_URL=http://127.0.0.1:8545 HOOK_ADDRESS=<deployed> cargo run -- monitor
RPC_URL=http://127.0.0.1:8545 HOOK_ADDRESS=<deployed> cargo run -- simulate 1.0 true
```

### 5. Feed live prices (keeper)

```bash
cargo run -- keeper       # needs PYTH_API_KEY + DEPLOYMENT_KEY in .env
```

Polls Hermes every 5 s and publishes fresh signed payloads to the Pyth
store (measured payload age 0–2 s) — see
[Price feeding](#price-feeding-hermes-keeper--verified-keyless-replay).

---

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Smart Contracts | Solidity | 0.8.26 |
| Hook Framework | Uniswap V4 `BaseHook` | v4-core (cancun) |
| Oracle | Pyth Network | pull model, confidence bands |
| Tooling Language | Rust | 2021 edition |
| Ethereum Client | ethers-rs | 2.0 |
| Async Runtime | tokio | 1.x |
| Build / Test | Foundry (forge, cast) | — |

---

## Gas & Sizing

- **Optimizer:** 50 runs, `via_ir` enabled, `sparse_mode`, `bytecode_hash = "none"`
- **Deployed `DetoxHook`:** ≈ 10.4 KB (well under the 24 KB EIP-170 limit)
- **Exact-output swaps:** exit at the top of `_beforeSwap` with no oracle work
- **Exact-input swaps:** two Pyth reads + slot0 read, then either a pass-through return or, on a detected arb, `take` + `donate` + `settle` (full flow exercised by `DetoxHookCapture.t.sol`)
- No proxy, no upgrade path — redeploy to change logic

---

## Security Considerations

| Risk | Mitigation |
|------|-----------|
| Oracle manipulation | Capture requires the pool price to sit **outside** Pyth's confidence band **and** deviate ≥ 2%; low-confidence prices widen the band and suppress triggers |
| Stale prices | `stalenessThreshold` (live: **60 s**, kept fresh by `keeper`) — stale/invalid prices make the hook pass every swap through |
| Reentrancy | No guard is used: the hook only calls `PoolManager` (trusted) and Pyth (staticcall), and completes take/donate/settle inside a single `beforeSwap`/`afterSwap` frame. *(An earlier "nonce-based reentrancy guard" claim was not in the code and has been removed.)* |
| Swapper griefing | Fail-open on every error path; capture clamped to 50% of input (`MAX_CAPTURE_BPS`); `int128` range checked; empty pools skipped |
| Fee-override scope | The 0.30% override only applies to **dynamic-fee** pools; static-fee pools keep their configured fee (documented, not silently broken) |
| Hook token balance | Capture takes from the pool and settles from the same receipt — the hook never needs pre-funding, and keeps only `hookKept` |
| Owner key compromise | Use a multisig for `owner`; all `onlyOwner` paths are parameter/fee/withdraw only |
| Flashloan attacks | The hook reads prices and moves funds only within one unlock; it holds no user deposits |

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Change `avenge-rs/` (Rust) or `detox-hook/packages/foundry/src/` (Solidity)
4. Add tests for new functionality
5. Make sure `forge test` and `cargo test` both pass
6. Commit and open a Pull Request

---

## License

MIT

---

## Acknowledgments

- [Uniswap V4](https://docs.uniswap.org/contracts/v4/overview) — hook framework
- [Pyth Network](https://docs.pyth.network/) — real-time oracle prices
- [Foundry](https://book.getfoundry.sh/) — Solidity toolchain
- [ethers-rs](https://docs.rs/ethers) — Ethereum Rust library

---

<p align="center">
  <strong>AvengeHook — where MEV benefits everyone, not just the bots.</strong>
</p>
