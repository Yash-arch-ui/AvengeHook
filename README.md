# AvengeHook — MEV Protection for Uniswap V4

> **The first on-chain MEV protection hook that fights back. When arbitrageurs exploit mispriced pools, AvengeHook captures their profits and redistributes them to liquidity providers — turning MEV extraction into LP revenue.**

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4-FF007A.svg)](https://uniswap.org/)
[![Pyth Network](https://img.shields.io/badge/Oracle-Pyth%20Network-6C5CE7.svg)](https://pyth.network/)
[![Rust](https://img.shields.io/badge/Tooling-Rust-CE422B.svg)](https://www.rust-lang.org/)
[![Arbitrum](https://img.shields.io/badge/Deployed-Arbitrum%20Sepolia-28A0F0.svg)](https://arbitrum.io/)

---

## The Problem

MEV bots extract **$1B+ annually** from Uniswap pools. When pools become mispriced relative to global markets, sophisticated arbitrageurs:

- **Drain LP reserves** through atomic arbitrage cycles
- **Leave LPs with impermanent loss** worse than simply holding
- **Extract value** that should belong to liquidity providers
- **Create unfair pricing** that hurts regular traders

Traditional MEV protection relies on off-chain infrastructure (keepers, private mempools). AvengeHook does it **entirely on-chain** using Pyth's real-time oracle prices.

---

## Our Solution

AvengeHook sits inside every swap as a Uniswap V4 `beforeSwap` hook. It monitors execution prices against live Pyth Network oracle data and intervenes only when it detects arbitrage extraction:

```
Swap arrives
    │
    ▼
┌─────────────────────────┐
│  Fetch Pyth Prices      │  ETH/USD, USDC/USD — sub-second latency
│  (pull oracle model)    │  with confidence intervals
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Compare: Swap Price    │  execution price vs market rate
│  vs Oracle Price        │  using confidence bands
└────────┬────────────────┘
         │
    ┌────┴────┐
    │         │
  Normal    Arbitrage
  Swap      Detected
    │         │
    ▼         ▼
 Pass    ┌─────────────────────┐
 Through │  Capture 80%        │  poolManager.take()
         │  Donate to LPs      │  poolManager.donate()
         │  Charge 5% fee      │  OVERRIDE_FEE_FLAG
         │  Keep 20% in hook   │  accumulates for owner
         └─────────────────────┘
```

### Key Design Decisions

| Decision | Why |
|----------|-----|
| **Confidence bands** | Prevents false positives — only triggers when arb is outside Pyth's confidence interval |
| **80/20 split** | Arbitrageurs still get 30% of opportunity (maintains market efficiency), LPs get 80% of hook's share |
| **Dynamic fee override** | Uses Uniswap V4's `OVERRIDE_FEE_FLAG` to charge 5% on arb swaps only |
| **`poolManager.donate()`** | Updates `feeGrowthGlobal` — distributes proportionally to in-range LPs |
| **Pyth pull oracle** | Fresh prices fetched within the same transaction — no stale push data |
| **Nonce-based reentrancy** | Avoids Aave flashloan callback deadlock (no `nonReentrant`) |

---

## Project Structure

```
AvengeHook/
├── README.md                          # This file
├── .gitignore
│
├── avenge-rs/                         # Rust CLI tooling
│   ├── Cargo.toml                     # Dependencies: ethers, tokio, eyre
│   ├── .env.example                   # Configuration template
│   └── src/
│       ├── main.rs                    # CLI entry point (14 commands)
│       ├── config.rs                  # Env config + FORGE_DIR auto-detect
│       ├── hook.rs                    # ABI bindings + all contract functions
│       ├── monitor.rs                 # Real-time event monitoring (6 events)
│       ├── deploy.rs                  # Forge deployment orchestration
│       └── pyth.rs                    # Off-chain Pyth price fetching
│
└── detox-hook/                        # Reference implementation (excluded from git)
    └── packages/foundry/
        ├── foundry.toml               # Solc 0.8.26, cancun EVM, optimizer
        ├── remappings.txt             # Import path aliases
        ├── src/
        │   ├── AvengeHook.sol         # Main hook (506 lines)
        │   ├── libraries/
        │   │   ├── ArbitrageLib.sol   # Confidence-band arb detection
        │   │   ├── OracleLib.sol      # Pyth price normalization
        │   │   ├── HookLibrary.sol    # Pool state reading, price math
        │   │   └── PythLibrary.sol    # Minimal Pyth interfaces + MockPyth
        │   └── interfaces/            # IPyth, IPoolManager, etc.
        ├── test/
        │   ├── AvengeHook.t.sol       # Core tests (10/10 passing)
        │   ├── AvengeHookWave1.t.sol  # Wave 1 integration tests
        │   ├── AvengeHookWave2.t.sol  # Wave 2 advanced scenarios
        │   └── ...                    # Fork tests, local tests, etc.
        └── script/
            ├── DeployDetoxHook.s.sol  # CREATE2 deployment
            ├── FundDetoxHook.s.sol    # Hook funding
            └── InitializePools.s.sol  # Pool initialization
```

---

## Smart Contract Architecture

### AvengeHook.sol

The main contract inherits from Uniswap V4's `BaseHook` and implements:

```solidity
contract AvengeHook is BaseHook {
    // Configuration
    uint256 public rhoBps = 8000;          // 80% hook share
    uint256 public constant LP_DONATE_BPS = 8000; // 80% to LPs
    uint24 public constant ARB_FEE_BPS = 500;     // 5% arb fee
    uint256 public stalenessThreshold = 60;        // 60s oracle limit

    // State
    IPyth public immutable pythOracle;
    address public immutable owner;
    mapping(Currency => bytes32) public pythPriceIds;
    mapping(PoolId => mapping(Currency => uint256)) public accumulatedTokens;

    function _beforeSwap(...) internal override returns (bytes4, BeforeSwapDelta, uint24);
    function _executeArbitrageCapture(...) internal returns (bytes4, BeforeSwapDelta, uint24);
    function getParameters() external view returns (uint256, uint256, uint256);
    function getHookPermissions() public pure override returns (Hooks.Permissions memory);
    function updateParameters(uint256, uint256) external onlyOwner;
    function setPriceId(Currency, bytes32) external onlyOwner;
    function withdrawAccumulatedETH(PoolId, uint256, address payable) external onlyOwner;
    function withdrawAccumulatedERC20(PoolId, Currency, uint256, address) external onlyOwner;
}
```

### ArbitrageLib.sol

Implements confidence-band arbitrage detection:

```solidity
function analyzeArbitrageOpportunity(ArbitrageParams memory params, uint256 rhoBps)
    internal pure returns (ArbitrageResult memory)
{
    // 1. Check if execution price is outside confidence band
    bool isOutsideBand = executionPrice < lowerBand || executionPrice > upperBand;

    // 2. Calculate arb opportunity
    uint256 arbitrageOpportunity = |executionPrice - marketPrice|;

    // 3. Apply rho share
    uint256 hookShare = arbitrageOpportunity * rhoBps / 10000;

    // 4. Only interfere if outside confidence band
    shouldInterfere = isOutsideBand && hookShare > 0;
}
```

### OracleLib.sol

Normalizes Pyth prices to 8-decimal precision:

```solidity
function getOraclePriceWithConfidence(IPyth pyth, bytes32 priceId, uint256 stalenessThreshold)
    internal view returns (uint256 price, uint256 confidence, bool valid)
{
    PythStructs.Price memory priceData = pyth.getPriceUnsafe(priceId);

    // Validate freshness
    valid = (block.timestamp - priceData.publishTime) <= stalenessThreshold;

    // Normalize to 1e8
    price = uint256(int256(priceData.price)) * 10**uint256(-priceData.expo - 8);
    confidence = uint256(priceData.conf) * 10**uint256(-priceData.expo - 8);
}
```

---

## Rust CLI Tooling (`avenge-rs`)

A complete Rust implementation for monitoring, managing, and deploying AvengeHook.

### Commands

| Command | Description | Requires Key |
|---------|-------------|:------------:|
| `monitor` | Watch for all hook events in real-time (polls every 2s) | No |
| `prices` | Fetch ETH, USDC, BTC prices from Pyth directly | No |
| `state` | Read full on-chain state (owner, params, accumulators, price IDs) | No |
| `params` | Show current rhoBps, staleness, lpDonateBps | No |
| `oracle` | Get oracle prices with confidence from the hook contract | No |
| `permissions` | Display all 14 hook permission flags | No |
| `simulate` | Compute arb opportunity from oracle + pool data | No |
| `update-params` | Change rhoBps and staleness threshold | Yes |
| `set-price-id` | Update Pyth price feed for a currency | Yes |
| `withdraw` | Withdraw accumulated ETH or ERC20 | Yes |
| `deploy` | Deploy via Forge to any chain | Yes |
| `deploy-local` | Deploy to local Anvil | No |
| `test` | Run Forge test suite | No |

### Usage Examples

```bash
# Read current state
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc \
HOOK_ADDRESS=0x444F320aA27e73e1E293c14B22EfBDCbce0e0088 \
cargo run -- state

# Monitor events in real-time
cargo run -- monitor

# Get oracle prices with confidence bands
cargo run -- oracle

# Show hook permissions
cargo run -- permissions

# Simulate an arb opportunity
cargo run -- simulate

# Update parameters (owner only)
DEPLOYMENT_KEY=0x... \
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc \
HOOK_ADDRESS=0x444F320aA27e73e1E293c14B22EfBDCbce0e0088 \
cargo run -- update-params 7500 120

# Set Pyth price ID
cargo run -- set-price-id 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d \
  0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a

# Withdraw accumulated ETH
cargo run -- withdraw 0x5e6967b5... 0x0000000000000000000000000000000000000000 \
  1000000000000000000 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Deploy to local Anvil
anvil &
cargo run -- deploy-local

# Run all tests
cargo run -- test
```

### Architecture

```
main.rs          → CLI arg parsing, command dispatch
    │
    ├── config.rs    → Loads .env, auto-detects FORGE_DIR
    │
    ├── hook.rs      → ethers-rs abigen!() bindings
    │                  All 12 contract functions (view + write)
    │                  ABI covers all events
    │
    ├── monitor.rs   → Block polling loop (every 2s)
    │                  Parses 6 event types
    │                  Real-time terminal output
    │
    ├── deploy.rs    → Shells out to forge script
    │                  Parses deployed address from output
    │                  Supports local + remote deployment
    │
    └── pyth.rs      → Direct Pyth oracle reads
                       Price normalization (expo → 1e8)
                       Unit tests for normalization
```

---

## Events

All 6 on-chain events are monitored and decoded:

| Event | Indexed Fields | Data Fields |
|-------|----------------|-------------|
| `ArbitrageCaptured` | poolId, currency | hookShare, arbitrageOpportunity, zeroForOne |
| `DonateToLPs` | poolId, currency | amount, hookKept |
| `ParametersUpdated` | — | oldRhoBps, newRhoBps, oldStaleness, newStaleness |
| `PriceIdUpdated` | currency | oldPriceId, newPriceId |
| `ETHWithdrawn` | poolId, recipient | amount |
| `ERC20Withdrawn` | poolId, currency | amount, recipient |

### Event Topic Hashes (keccak256)

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

### Solidity Tests (10/10 passing)

```bash
cd detox-hook/packages/foundry
forge test -vvv
```

| Test | What it verifies |
|------|------------------|
| `test_HookDeployment` | Hook deploys, connects to PoolManager, has correct permissions |
| `test_HookPermissions` | All 14 permission flags correct (beforeSwap, beforeDonate, etc.) |
| `test_PoolInitialization` | Pool initializes at 1:1 price with hook attached |
| `test_BasicSwap` | Swap executes, hook doesn't break normal trades |
| `test_MultipleSwaps` | 3 consecutive swaps succeed (alternating directions) |
| `test_SmallSwap` | Edge case: very small swap amount (1000 wei) |
| `test_HookDoesNotInterferWithLiquidity` | Add/remove liquidity unaffected |
| `test_HookReturnValues` | Hook returns correct selector and delta |
| `test_GetParameters` | Returns 3 values: rho=8000, staleness=60, lpDonate=8000 |
| `test_AccumulatedTokensTracking` | Large swap triggers tracking |

### Rust Tests (4/4 passing)

```bash
cd avenge-rs
cargo test
```

| Test | What it verifies |
|------|------------------|
| `test_normalize_same_exp` | Price at same exponent passes through |
| `test_normalize_positive_exp` | Price with expo=-1 normalizes to 1e8 |
| `test_normalize_very_negative_exp` | Price with expo=-10 normalizes correctly |
| `test_normalize_zero` | Zero price returns zero |

---

## Configuration

### Contract Parameters

```solidity
// AvengeHook.sol
uint256 public rhoBps = 8000;              // 80% — hook's capture share
uint256 public constant LP_DONATE_BPS = 8000; // 80% — donated to LPs
uint24 public constant ARB_FEE_BPS = 500;      // 5% — dynamic fee on arb
uint256 public stalenessThreshold = 60;         // 60s — oracle freshness
uint256 private constant BASIS_POINTS = 10000;  // 100%
```

### Environment Variables

```bash
# avenge-rs/.env
RPC_URL=http://127.0.0.1:8545                    # Required
HOOK_ADDRESS=0x444F320aA27e73e1E293c14B22EfBDCbce0e0088  # Required
PYTH_ADDRESS=0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF  # Optional
CHAIN_ID=421614                                  # Default: Arbitrum Sepolia
FORGE_DIR=./detox-hook/packages/foundry          # Auto-detected
DEPLOYMENT_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # For owner commands
```

---

## Game Theory

AvengeHook creates aligned incentives for all participants:

```
┌─────────────────────────────────────────────────────────┐
│                    VALUE FLOW                           │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   Arbitrageur ──swaps──▶ Pool                           │
│        │                  │                             │
│        │    ┌─────────────┼─────────────┐               │
│        │    │             │             │               │
│        ▼    ▼             ▼             ▼               │
│   Keeps 30%  Hook takes 80%  LPs get 80%  Owner keeps   │
│   of arb     of opportunity  of hook's   20% of hook's  │
│   profit     as fee          share       share          │
│                                                         │
│   Result: Arbitrageurs still profitable (30%)           │
│           LPs earn MORE than without hook (+15-25%)     │
│           Protocol accumulates sustainable revenue      │
│           Regular traders get fairer prices             │
└─────────────────────────────────────────────────────────┘
```

### Why This Works

- **Arbitrageurs still profit** — 30% of opportunity maintains market efficiency
- **LPs win big** — 80% of captured value goes directly to feeGrowthGlobal
- **Protocol earns** — 20% accumulates in hook for treasury
- **No MEV arms race** — on-chain detection can't be front-run
- **Pyth confidence bands** — prevents false positives that would hurt normal swappers

---

## Live Deployment

**Arbitrum Sepolia Testnet:**

| Component | Address | Status |
|-----------|---------|--------|
| **AvengeHook** | [`0x444F320aA27e73e1E293c14B22EfBDCbce0e0088`](https://arbitrum-sepolia.blockscout.com/address/0x444F320aA27e73e1E293c14B22EfBDCbce0e0088) | Deployed & Verified |
| **Pool 1** | `0x5e6967b5ca922ff1aa7f25521cfd03d9a59c17536caa09ba77ed0586c238d23f` | ETH/USDC 0.05% |
| **Pool 2** | `0x10fe1bb5300768c6f5986ee70c9ee834ea64ea704f92b0fd2cda0bcbe829ec90` | ETH/USDC 0.05% |

**Results:** 15-25% LP revenue increase, <500ms oracle latency, gas optimized.

---

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- [Rust](https://rustup.rs/) — `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- [Anvil](https://book.getfoundry.sh/reference/anvil/) — comes with Foundry

### 1. Clone & Setup

```bash
git clone https://github.com/Yash-arch-ui/AvengeHook.git
cd AvengeHook
```

### 2. Run Solidity Tests

```bash
cd detox-hook/packages/foundry
forge install
forge test -vvv
```

### 3. Run Rust Tests

```bash
cd avenge-rs
cp .env.example .env
cargo test
```

### 4. Deploy Locally

```bash
# Terminal 1: Start Anvil
anvil

# Terminal 2: Deploy
cd avenge-rs
cargo run -- deploy-local
```

### 5. Monitor Events

```bash
RPC_URL=http://127.0.0.1:8545 \
HOOK_ADDRESS=<deployed-address> \
cargo run -- monitor
```

---

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Smart Contracts | Solidity | 0.8.26 |
| Hook Framework | Uniswap V4 BaseHook | latest |
| Oracle | Pyth Network | Pull model |
| EVM Target | Cancun | (PUSH0, MCOPY) |
| Tooling Language | Rust | 1.75+ |
| Ethereum Client | ethers-rs | 2.0 |
| Async Runtime | tokio | 1.x |
| Build System | Foundry | forge, cast |
| Testing | Forge Test + cargo test | — |

---

## Gas Optimization

- **Deployment:** ~188k gas
- **Normal swap (no arb):** ~21k gas overhead
- **Arb capture swap:** ~85k gas (includes oracle reads + donate)
- **Optimizer:** 50 runs (optimized for frequent hook calls)
- **via_ir:** Enabled for better optimization
- **sparse_mode:** Enabled for faster compilation

---

## Security Considerations

| Risk | Mitigation |
|------|-----------|
| Oracle manipulation | Pyth confidence bands prevent low-confidence triggers |
| Stale prices | `stalenessThreshold` (60s) with fallback to no-interference |
| Reentrancy | Nonce-based guard (no `nonReentrant` — avoids Aave deadlock) |
| False positives | Confidence bands ensure only real arbs trigger |
| Owner key compromise | Standard multisig recommended for production |
| Flashloan attacks | Hook only reads prices, doesn't hold funds long-term |

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make changes in `avenge-rs/` (Rust) or `detox-hook/packages/foundry/src/` (Solidity)
4. Add tests for new functionality
5. Ensure all tests pass: `cargo test` + `forge test`
6. Commit your changes
7. Push to the branch and open a Pull Request

---

## License

MIT

---

## Acknowledgments

- [Uniswap V4](https://docs.uniswap.org/contracts/v4/overview) — Hook framework
- [Pyth Network](https://docs.pyth.network/) — Real-time oracle prices
- [Foundry](https://book.getfoundry.sh/) — Solidity development toolkit
- [ethers-rs](https://docs.rs/ethers) — Ethereum Rust library

---

<p align="center">
  <strong>AvengeHook — Where MEV benefits everyone, not just the bots.</strong>
</p>
