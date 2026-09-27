# Market-scenario testing via `avenge-rs` — demo runbook

> Copy-paste runbook for exercising every market scenario live.
> **Setup:** repo root = this file's folder. Terminal A: `cd avenge-rs`.
> Owner key + RPC come from `avenge-rs/.env` (auto-loaded by the CLI).

---

## 0. Pre-flight (60 s)

```bash
cd avenge-rs

# Terminal A — start the price keeper (leave running)
cargo run -q -- keeper          # Hermes → store every 5 s, ages 0–2 s

# Terminal B — health check
cargo run -q -- params          # rhoBps 7000 | staleness 60 | lpDonateBps 8000
cargo run -q -- oracle          # BOTH lines: valid: true, publishTime ≈ now
cargo run -q -- permissions     # 14 flags, beforeSwap/beforeDonate set
```

**Green light:** `oracle` says `valid: true` ×2 with a fresh `publishTime`.
If not → run `cargo run -q -- keeper 5 5` once and re-check.

---

## Scenario matrix

| # | Scenario | Tool | Expect |
|---|----------|------|--------|
| S1 | Baseline healthy market | `oracle`, `live-prices` | `valid: true`, age < 60 s |
| S2 | Arb decision, both directions | `simulate` | decision fields explainable |
| S3 | End-to-end capture (deterministic) | forge suites | 8+10 tests PASS |
| S4 | Stale oracle → fail-open | stop keeper, wait | `valid: false`, no interference |
| S5 | Keeper freshness live | `keeper 5 5` | age 0–2 s, 20 wei, status 1 |
| S6 | Confidence band / low-conf logic | forge suites | 21+23 tests PASS |
| S7 | Parameter sweep (rho) | `update-params` | `hookShare` follows rhoBps |
| S8 | Capture accounting → withdraw | `state` → swap → `state` | accumulators move |
| S9 | Live event stream | `monitor` | 6 event types decoded |
| S10 | Full regression | `cargo test`, `forge test` | 14/14 + 136/136 |

---

## S1 — Baseline (healthy market)

```bash
cargo run -q -- oracle
cargo run -q -- live-prices      # age vs 60 s window + RPC latency
cargo run -q -- prices           # Pyth prices with confidence bands
```
**Expect:** `valid: true` both feeds, age a few seconds.
**Say:** *"Freshness is enforced on-chain: prices >60 s old are refused by the hook."*

---

## S2 — Arb decision, both directions (read-only)

```bash
cargo run -q -- simulate 1.0 true    # selling ETH  (zeroForOne)
cargo run -q -- simulate 100 false   # selling USDC (oneForZero)
```
**Read the 5 fields:**
| Field | Meaning |
|---|---|
| `arbitrageOpp` | raw opportunity size (token0 units) |
| `hookShare` | `rhoBps`-based cut the hook would keep |
| `shouldInterfere` | **the verdict**: outside band **and** ≥2% deviating **and** advantageous |
| `outsideConfBand` | pool price vs Pyth confidence band |
| `hint` | normalization/units reminder |

**Say:** *"The hook only intervenes when the pool price is outside Pyth's
confidence band AND deviates ≥2% — ordinary volatility is never taxed."*
**Note:** verdict is live data — if the pool is already converged,
`shouldInterfere: false` IS the correct story (arbitrageurs fixed it).

---

## S3 — End-to-end capture (deterministic, offline)

```bash
cd ../avenge-hook/packages/foundry

forge test --match-path test/AvengeHookCapture.t.sol -vv      # 8: take→donate→keep both dirs, caps, stale-oracle, external donate
forge test --match-path test/AvengeHookWave2.t.sol -vv        # 10: both directions, threshold edges, param updates
```
**Named tests to point at:**
- `test_CaptureZeroForOne_PaysLPsAndKeepsShare` / `…OneForZero…` — full money flow
- `test_NoCaptureWhenOracleStale` — fail-open proof
- `test_NoCaptureWhenPricesAgree` — no false positives
- `test_CaptureCappedAtMaxCaptureBps` — 50% cap
- `test_ExternalDonateDoesNotRevert` — third-party `donate()` works

**Say:** *"This suite is the business logic under test — exact split
70% capture → 80% of it to LPs, remainder to the hook."*

---

## S4 — Stale oracle → fail-open (the safety demo)

```bash
# 1. Stop the keeper (Ctrl-C in Terminal A)
# 2. Wait ~70 seconds
cargo run -q -- oracle            # expect: valid: false (publishTime older than 60 s)
cargo run -q -- simulate 1.0 true # expect: shouldInterfere: false
# 3. Restart:
cargo run -q -- keeper            # within ~10 s:
cargo run -q -- oracle            # valid: true again
```
**Say:** *"If data goes stale the hook passes swaps through untouched —
fail-open by design, never trades on old prices."*

---

## S5 — Keeper freshness (the headline number)

```bash
cargo run -q -- keeper 5 5        # 5 polls, then exits
```
**Expect (real output):** every line `age=0–2s → 0x… fee=20 wei`,
status 1 txs, prices moving with the market.
**Then:** `cargo run -q -- oracle` → publishTime within seconds of now.
**Say:** *"Payload age 0–2 s end-to-end ≈5 s freshness against a 60 s
window — well inside the ~1–2 min the README promises."*

---

## S6 — Confidence-band & math logic

```bash
cd ../avenge-hook/packages/foundry
forge test --match-path test/ArbitrageLib.t.sol -vv   # 21: band bounds, threshold edges
forge test --match-path test/OracleLib.t.sol -vv      # 23: staleness, invalid/zero/negative, expo math
```
**Point at:** `test_shouldInterfere_InsideBandEvenIfAdvantageous`,
`test_shouldInterfere_OutsideBandButNotAdvantageous`,
`test_isPriceValid_StalePrice`, `test_normalizePythPrice_NegativeExponent`.
**Say:** *"Both gates are tested in isolation — band AND threshold AND
advantage must all hold."*

---

## S7 — Parameter sweep (owner powers)

```bash
cargo run -q -- params                    # before: rhoBps 7000 (hookShare 70%)
cargo run -q -- update-params 5000 60     # owner tx ~30 710 gas
cargo run -q -- simulate 1.0 true         # hookShare now tracks 50%
cargo run -q -- update-params 7000 60     # restore
cargo run -q -- params
```
**Say:** *"Capture share and staleness are owner-tunable on-chain —
governance without redeploy."*

---

## S8 — Capture accounting (state → action → state)

```bash
cargo run -q -- state                # accumulatedTokens per pool/currency (before)

# Optional live swap — same shape as the verified capture tx 0x85dd8e54…61490
# (sells 1 USDC through PoolSwapTest; approve first). Run from avenge-rs/ so .env loads:
set -a && . ./.env && set +a
cast send 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d \
  'approve(address,uint256)' 0xf3A39C86dbd13C45365E57FB90fe413371F65AF8 1000000 \
  --private-key $DEPLOYMENT_KEY --rpc-url $RPC_URL
cast send 0xf3A39C86dbd13C45365E57FB90fe413371F65AF8 \
  'swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)' \
  '(0x0000000000000000000000000000000000000000,0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d,8388608,30,0xf53c43858D62a1765480508f3bE7481e883380A8)' \
  '(false,-1000000,1461446703485210103287273052203988822378723970342)' \
  '(false,false)' '' \
  --private-key $DEPLOYMENT_KEY --rpc-url $RPC_URL

cargo run -q -- state                # accumulators after; capture only if market was mispriced
```
**Then withdraw (owner):**
```bash
cargo run -q -- withdraw \
  0x5771f78e1245220ba528309807e28c9bad50849292b2a694ffba8958196c9c4b \
  0x0000000000000000000000000000000000000000 \
  <amount> 0x767166724ec61042ea01c43278b94471C950B824
```
**Say:** *"LPs get 80% of every capture via donate(), hook keeps 14%,
protocol keeps the rest — all visible in `state`."*
*(If the market is not mispriced the swap passes through — that's S2's
"no false positives" claim, demonstrated live.)*

---

## S9 — Live event stream

```bash
cargo run -q -- monitor     # Terminal A — 2 s poll, 6 event types
# …then run the S8 swap in Terminal B and watch it print:
#    ArbitrageCaptured / DonateToLPs / ParametersUpdated / …
```

---

## S10 — Full regression (the receipts)

```bash
cd avenge-rs && cargo test                       # 14/14 (unit: normalize, keeper fixtures, freshness)
cd ../avenge-hook/packages/foundry && forge test  # 136/136, 13 suites (fork suite needs internet)
```

---

## 60-second pitch (for the interviewer)

> "This is a Uniswap v4 hook that defends an LP pool against oracle-lag
> arbitrage **on-chain**: it compares the pool price against Pyth's confidence
> band, interferes only past a 2% threshold, and splits the captured value
> 70% at swap time → 80% of that to LPs. Prices are kept 0–2 s fresh by a Rust
> keeper that replays signed Pyth payloads (20 wei each) into the store, with
> a 60 s staleness window that fails open. 14 Rust unit tests + 136 Solidity
> tests cover capture math, caps, staleness and real fork swaps."

## Troubleshooting

| Symptom | Fix |
|---|---|
| `oracle valid:false` | keeper not running / key expired → `cargo run -q -- keeper` |
| `oracle` errors on RPC | use `cast` for heavy RPC calls (public RPC rate-limits urllib) |
| keeper `401` | trial key expired (14 d) → new free key at pythdata.app → `.env` |
| fork suite fails | needs internet (`https://sepolia-rollup.arbitrum.io/rpc`) |
| swap reverts | market not mispriced (expected) or approve missing — re-run approve step |
