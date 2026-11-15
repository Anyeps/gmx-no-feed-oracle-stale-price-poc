# G-P0-7 — No-feed index tokens skip the oracle deviation check — FINDINGS

**Verdict: FOUND (keeper path only, measured) — but the user-executable atomic
path is BLOCKED by design, and the keeper path needs a permissioned keeper.
Severity: real, limited, matches no listed Immunefi impact; expect Medium at
best and a real risk of "intended behaviour" triage. See §6.**

Fork block: **524367000** (Arbitrum). Market: ZORA
`0xac484106d935f0f20F1485b631fA6F65AeEff550`, index ZORA
`0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a`, P0 = $0.004431 (GMX API,
15 Nov ~12:00 WIB). All tests local fork only; no mainnet, no real funds.

## 1. The finding (config level, confirmed live)

56 index tokens in live-listed markets have **no Chainlink price feed**
(`PRICE_FEED` = 0), so `Oracle._validatePrices` skips the 50%
reference-deviation check entirely for them. Only the 300s age bound
(`MAX_ORACLE_PRICE_AGE`) and the 60s timestamp-range bound
(`MAX_ORACLE_TIMESTAMP_RANGE`) bind. 45 from the dump (43 synthetic
placeholders + 2 real: ANIME, EIGEN) + 11 newer markets + wstETH
long/short-only. No `StaticOracleProvider` exists on Arbitrum; majors all
have feeds. Recon: `RECON-RESULTS.md`, `recon.json`.

The question was whether the missing deviation check is exploitable: can a
stale signed report (from before a price move) be used to fill at the old
price, extracting value from the pool / remaining LPs?

## 2. Keeper order path — FOUND, measured

A keeper executing an order with a **299s-old** signed report (inside the
300s bound) fills at the pre-move price. ZORA market, direct-price control
arms use fresh prices.

| test | setup | result |
|---|---|---|
| K1 | $2,000 long, +25% pump, 299s-old report | filled at P0, worth **$2,499 → gain $499** (24.95%) |
| K1c | control, fresh report at pumped price | worth **$1,999** (gain $0) |
| K2 | 301s-old report | **reverts** (age bound binds) |
| K3 | $2,000 long, +10% pump, 299s-old report | worth **$2,199 → gain $199** (9.95%) |
| K4 | $4,000 long, +25% pump, 299s-old report | worth **$4,999 → gain $999** (24.98%) |

Tokens filled exactly match the P0 expectation (zero price impact). 5/5 pass
(`test/GP07Keeper.t.sol`).

**Caveat (decisive):** execution needs a keeper to submit the stale report.
Users cannot self-execute orders — `executeOrder` is `onlyOrderKeeper`, and
the keeper chooses the oracle params. A user cannot force a keeper to use a
299s-old report; the attack needs a malicious or colluding keeper (a
permissioned `ORDER_KEEPER` role). This is the same bar G-P0-1 failed on,
except here there is NO configured tolerance to be inside of — the deviation
check simply does not exist for these tokens. In the real world a 299s-old
signed Data Streams report is obtainable (reports are public), so report
availability is not the blocker; keeper cooperation is.

## 3. Atomic withdrawal path — NOT FOUND (blocked by design)

`executeAtomicWithdrawal` is external with no role check, so it looked like
the user-executable route: withdraw GM with a ≤30s-old pre-move report.
**It cannot work.** The recon missed a second check that binds first:

`contracts/withdrawal/ExecuteWithdrawalUtils.sol:100`
```solidity
if (params.oracle.minTimestamp() < withdrawal.updatedAtTime())
    revert Errors.OracleTimestampsAreSmallerThanRequired(...);
```
This applies to **every** withdrawal (atomic and keeper-executed). For atomic
withdrawals the withdrawal is created inside the same call, so
`updatedAtTime ==` the execution block timestamp, and **any report older
than "now" is rejected**. The 30s age bound is strictly weaker for atomic
withdrawals — the creation-time check is the binding one.

| test | setup | result |
|---|---|---|
| A1 | $2,000 GM + $4,000 short, −25%, atomic withdraw, 25s-old report | **reverts** `OracleTimestampsAreSmallerThanRequired(T0, T0+25)` |
| A1b | GM-only, −25%, 25s-old report | **reverts** (same) |
| A3 | GM-only, +25%, 25s-old report | **reverts** (same — direction irrelevant) |
| A1c | control, fresh report at fallen price | executes, redeems **$1,887** |
| A1bc | GM-only control, fresh, −25% | executes, redeems **$2,060** |
| A3c | GM-only control, fresh, +25% | executes, redeems **$1,914** |
| A2 | 31s-old atomic report | **reverts** `MaxPriceAgeExceeded` (30s bound also binds; the modifier fires first) |

10/10 atomic tests pass (`test/GP07Atomic.t.sol`, incl. W1/W1c below).
The atomic path is a genuine negative: the protocol already defends it, by a
check that has nothing to do with the missing price feed.

## 4. Keeper withdrawal path — FOUND, measured, small (+$101)

The stale-price GM redemption **does** work through the keeper path, because
the withdrawal can be created *before* the move (`updatedAtTime == T0`) and
executed by a keeper at T0+299 with the 299s-old report (timestamp check
passes on equality; age 299s ≤ 300s). Same keeper-cooperation caveat as §2.

| test | setup | result |
|---|---|---|
| W1 | $2,000 GM + $4,000 short, −25%, withdrawal created at T0, keeper executes at T0+299 with 299s-old pre-fall report | redeems **$1,997** |
| W1c | control, keeper executes with fresh report at fallen price | redeems **$1,896** |
| W1vsW1c | same-run comparison (snapshot/revert) | **stale − fresh = $101** |

Why only $101 when the order path gains $499 on the same move? The
withdrawal gain is the withdrawer's pro-rata share (~17.35% of the pool) of
the pool-value difference, not the full position PnL — and the impact pool
partly offsets it (see §5). Decomposition of the $101:
- own $4,000 short gains $1,000 on the −25% fall → pool loses $1,000 →
  withdrawer's share −$173 (stale avoids this);
- the ZORA-denominated impact pool shrinks by $422 on the fall → pool
  gains $422 → withdrawer's share +$73 (this *helps* the fresh arm);
- pre-existing shorts' PnL contributes ~$0 (pinned at the withdrawal cap);
- net: +$173 − $73 = **+$100 ≈ measured $101**. ✓

## 5. Why the GM-only pool value moves the "wrong" way (impact pool)

The GM-only fresh arms looked inverted at first: after a −25% fall the pool
*redeems more* ($2,060) than the $2,000 deposit, and after a +25% pump it
redeems less ($1,914). The mechanism is in
`MarketUtils.getPoolValueInfo`:

```solidity
result.poolValue -= impactPoolUsd;   // impactPoolUsd = impactPoolAmount × indexTokenPrice
```

The position-impact pool is denominated in the **index token (ZORA)**, so its
USD deduction scales with the ZORA price. Measured on the fork
(`test/GP07OiProbe.t.sol`):

| | P0 $0.004431 | P1_DOWN −25% | P1_UP +25% |
|---|---|---|---|
| impactPoolUsd | $1,689 | $1,267 (−$422) | $2,111 (+$422) |

A fall shrinks the deduction → pool value rises $422 → GM share +$73
(17.35%). A pump grows it → pool falls $422. The pre-existing shorts
($20,418.57 OI, long ~$1) do **not** move the pool value across ±25%:
their uncapped PnL sits above the withdrawal cap
(`MAX_PNL_FACTOR_FOR_WITHDRAWALS` = 0.45 × shortTokenUsd ≈ $2,906), so the
capped PnL is pinned at the cap in all three price arms. (Positive PnL is
capped; negative PnL passes through uncapped — `getCappedPnl`.)

Two consequences worth recording:
- Any stale-price GM analysis on a no-feed market must account for the
  index-denominated impact pool; it systematically offsets the position-PnL
  effect (here by ~42% of the own-short contribution).
- The original prediction for A1bc/A3c was wrong for exactly this reason;
  the assertions were corrected to the measured values, not to the prediction.

## 6. Severity vs the listed Immunefi impacts

Listed impacts (verified live 2026-11-14): 5 Critical (10% of funds affected,
cap $5M), 2 High — **"Theft of unclaimed yield"** and **"Permanent freezing
of unclaimed yield"** — 6 Medium (griefing = NO profit motive).

- **Not Critical:** the gain is bounded by the order size and the price move
  inside a 300s window; it does not put 10% of funds at risk in one action,
  and it needs a permissioned keeper.
- **Not High as listed:** it is not theft/freezing of *unclaimed yield*.
  It is value extracted from the pool/LPs via a stale fill, which is a
  funds-at-risk shape but matches no listed High impact (same situation as
  G-P1-2(a)).
- **Not Medium (griefing):** griefing explicitly excludes profit-motive
  attacks; this one is profitable.
- **Realistic triage:** Medium at best; a strong chance of "intended
  behaviour" — the 300s age bound is an explicitly configured tolerance, so
  a 299s-old report is inside the protocol's own stated tolerance, and
  keepers are a trusted permissioned set. The atomic path (the one a
  standalone user could have used) is already defended.

Honest summary: a genuine, measured hole in oracle validation for no-feed
tokens (the deviation check is skipped entirely, not merely loosened), with
a working keeper-path exploit and a blocked atomic path. Reportable as a
Medium with the keeper-cooperation caveat stated up front; do not present it
as a standalone user exploit.

## 7. Limitations

- Mock-provider harness: the stale report is simulated with
  `MockOracleProvider7` (signed-report forgery is out of scope; real
  reports are public and obtainable, so this models the real primitive).
- The 25% move in 300s is extreme; realistic moves in 300s are smaller and
  the gain scales with the move (K3: +10% → $199 on $2,000).
- ZORA is the thinnest real no-feed market tested (pool ~$11,222, OI short
  $20,418.57); larger no-feed markets would scale the numbers but the
  mechanism is identical.
- The withdrawal gain depends on the market's impact-pool size and the
  withdrawer's pool share; it is not a fixed fraction of the move.

## 8. Files

- `test/GP07Keeper.t.sol` — K1/K1c/K2/K3/K4, 5/5 pass.
- `test/GP07Atomic.t.sol` — A1/A1b/A1c/A1bc/A2/A3/A3c/W1/W1c/W1vsW1c, 10/10 pass.
- `test/GP07Probe.t.sol`, `test/GP07OiProbe.t.sol` — market/OI/impact-pool/cap probes.
- `RECON-RESULTS.md`, `recon.json`, `analysis.txt` — recon (56 no-feed tokens).
- `src/`-adjacent: `contracts/` (copied harness), `IGmxV2.sol` extended with
  `executeAtomicWithdrawal`.
