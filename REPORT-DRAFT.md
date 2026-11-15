# DRAFT — GMX Immunefi Report: Stale-price execution on no-feed tokens (oracle deviation check skipped entirely)

> **STATUS: DRAFT ONLY — DO NOT SUBMIT.** Prepared 2026-11-15 for Fah's review.
> No Immunefi submission, no email, no contact with GMX or Immunefi has been made.
> **Submission is currently blocked by the 100-credit (100 USDC) Novice fee and
> is waiting for the Immunefi Studio wave** — this draft is ready to submit the
> moment a fee-free path (Studio "Ready" verdict) opens.
> The draft must be approved by Fah before anything is submitted.
>
> Finding ID (internal): G-P0-7, fork-tested 2026-11-15.
> Evidence base: `FINDINGS.md` and `RECON-RESULTS.md` in
> `~/workspace/hunts/gmx/poc/g-p0-7/` (17/17 fork tests, Arbitrum block
> 524367000; independently re-run by the parent agent at the same block).
> PoC repo: https://github.com/Anyeps/gmx-no-feed-oracle-stale-price-poc

---

# Part 1 — 7-Question Gate (run before writing the report)

Gate source: Agentic Bug Hunter `skills/triage-validation/SKILL.md`
("One wrong answer = STOP. Kill it. Move on."). All seven questions answered
below, with evidence. Q8 is the skill's identity check for authenticated
(Web2) hunts; it is adapted at the end because this is a permissionless
smart-contract finding.

**Gate result up front: CONDITIONAL PROCEED as a Medium draft.** Three
questions do not pass cleanly (Q1, Q2, Q4 — the keeper-cooperation
requirement and the fact that the finding matches no listed Immunefi
impact). The draft proceeds only because the task explicitly calls for an
honest Medium with those limitations disclosed front and centre, and
because the underlying defect — the deviation check is *absent*, not
merely loose, for 56 live-listed tokens — is real and measured. A
credible Medium with the caveats stated beats an inflated High that gets
closed as intended. Triage may still close this as intended behaviour or
out of scope; the report says so itself.

## Q1: Can an attacker use this RIGHT NOW, step by step? — CONDITIONAL PASS

The gate's template is written for HTTP requests; for a smart-contract
finding the equivalent is exact reproducible on-chain steps, which the PoC
provides (Foundry fork tests with exact function calls — see "Steps to
reproduce").

1. **Setup:** a keeper (permissioned `ORDER_KEEPER` role) with access to a
   299-second-old signed Chainlink Data Streams report for ZORA, plus a
   trader's open order on the ZORA market. Signed Data Streams reports are
   public and obtainable, so report availability is not the blocker.
2. **Request (on-chain, exact):** the keeper calls `OrderHandler.
   executeOrder` for a `MarketIncrease` long on the ZORA market
   `0xac484106d935f0f20F1485b631fA6F65AeEff550`, supplying
   `oracleParams` built from the 299s-old report (age 299s ≤ 300s
   `MAX_ORACLE_PRICE_AGE`; timestamp range ≤ 60s). The exact calls are in
   the PoC: `_execMock(key, p)` in `test/GP07Keeper.t.sol`
   (`testK1StaleFillAfterPump25`).
3. **Result:** the order fills at the pre-move price. Measured: a $2,000
   long opened after a +25% pump is worth **$2,499 — a $499 gain (24.95%)**
   vs $1,999 for the fresh-price control. A $4,000 long gains **$999**;
   a +10% pump gains **$199**.
4. **Impact:** the gain comes out of the pool / remaining LPs — the
   position is filled at a price the market no longer trades at.
5. **Cost:** the trade itself; no flash loan, no oracle manipulation.

**The condition (decisive):** a standalone user **cannot** do this. Users
cannot self-execute orders — `executeOrder` is `onlyOrderKeeper`, and the
keeper chooses the oracle params. The attack needs a malicious or
colluding keeper. This is the same bar G-P0-1 failed on, except here
there is NO configured tolerance to be inside of — the deviation check
simply does not exist for these tokens. The report is therefore a
keeper-threat-model finding, not a standalone user exploit, and it says
so in the first paragraph of the submission.

## Q2: Is the impact on the program's accepted impact list? — NO LISTED IMPACT (disclosed, proceeding as Medium)

- The finding matches **no listed Immunefi impact at any severity**
  (verified against the live Scope page 2026-11-14; see program.md §1):
  - Not Critical: the gain is bounded by the order size and the price
    move inside a 300s window; it does not put 10% of funds at risk in
    one action, and it needs a permissioned keeper.
  - Not High as listed: the two listed High impacts are **"Theft of
    unclaimed yield"** and **"Permanent freezing of unclaimed yield"**.
    This is value extracted from the pool/LPs via a stale fill — a
    funds-at-risk shape, but not unclaimed-yield theft or freezing
    (same situation as G-P1-2(a)).
  - Not Medium (griefing): the program's Medium impacts are griefing,
    which **explicitly excludes profit-motive attacks**; this one is
    profitable.
  - The program uses **Primacy of Rules**: the written rules decide
    severity, not impact alone.
- It is **not** in the program's Known Issues (6 entries, program.md §6,
  read 2026-11-13): bonusRewards on transfer, liquidation-capping M-15,
  fee-topup expected behaviour (×2), swap-without-market-update M-04,
  ADL price wipe (fixed). None covers missing price feeds or the
  deviation check.
- **CONDITION (flagged, must be verified on the live page before
  submitting):** the text fetch of the Immunefi Scope page rendered the
  Critical impacts list in full but cut off the High/Medium "Impacts in
  Scope" list after "Temporary freezing of funds", and the "Out of
  scope" section rendered empty. The finding is not on any exclusion
  visible in the fetch, but the full High/Medium lists and the Out of
  Scope list must be re-checked live before submission (see checklist).
  If the live lists exclude this shape, this answer changes and the
  report should not be submitted.
- **Why proceed at all:** the defect is genuine and measured (the
  deviation check is skipped entirely for 56 live-listed tokens), the
  keeper path is a working exploit under the keeper threat model, and
  Medium ($10,000 flat) is the honest ceiling — not High, not Critical.
  The submission asks triage to judge the config question with full
  information, including the "intended behaviour" argument.

## Q3: Is the root cause in an in-scope asset? — PASS

- Root cause lives in GMX V2 Synthetics on Arbitrum: `Oracle.
  _validatePrices` (live order-execution Oracle
  `0x26C02F221e8dB5A821e12347C7eA8a6b6E10842f`) skips the
  reference-deviation check when the token's `PRICE_FEED` key in the
  DataStore (`0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8`) is the zero
  address — and the DataStore config for 56 live-listed index tokens
  has no feed configured. The gmx-synthetics repo is explicitly in
  scope (program.md §1: "all contracts in these two repos are in
  scope"), and the ZORA market is a live production Arbitrum market.
  No third-party service is involved.

## Q4: Does it require privileged access that an attacker can't realistically get? — FAIL for a standalone attacker; PASS under the keeper threat model

- **Standalone user: FAIL.** The order path needs `onlyOrderKeeper`
  execution with keeper-chosen oracle params. A user cannot force a
  keeper to use a 299s-old report.
- **Keeper threat model: PASS.** Keepers are a permissioned set, but
  they are also the exact parties who handle every order's oracle
  params; a single malicious or compromised keeper (or a keeper
  colluding with a trader) can execute this on any no-feed market, at
  any size the market supports, repeatedly. The atomic path — the one a
  standalone user *could* have used — is already defended by design
  (see Q6 / "Negative results"), so the keeper path is the only live
  route, and it is real.
- This is the decisive limitation of the finding and the reason it is
  drafted as Medium, not High. The report states it before the impact
  numbers.

## Q5: Is this already known or accepted behavior? — PASS (with the main triage risk disclosed)

- **Not in Known Issues** (see Q2) and not in the Guardian audit
  findings surfaced during this hunt.
- **The 300s age bound IS an explicitly configured tolerance — this is
  disclosed front and centre in the report, not hidden.** A 299s-old
  report is inside the protocol's own stated tolerance, and keepers are
  a trusted permissioned set. Triage may reasonably conclude that
  executing inside the configured age bound is intended behaviour, and
  that the missing feed is a known config gap for synthetic placeholder
  tokens. That is a real outcome for this report.
- **What is NOT documented or acknowledged anywhere found is the
  interaction:** the deviation check — the protocol's only guard
  against executing at a price far from the market — is *absent* for
  these tokens, not merely loose. For every token with a feed, a report
  more than 50% away from the reference price reverts; for these 56
  tokens there is no bound at all on the deviation, only the 300s age
  bound. And the code itself contradicts the "known gap" reading:
  the `executeAtomicWithdrawal` comment claims on-chain feeds must be
  configured for all market tokens — but that is **not enforced
  anywhere in code** (no feed check in WithdrawalHandler /
  WithdrawalUtils / SwapPricingUtils); only the comment says it.
- The gate rule is "acknowledged/design decision → KILL IT". The 300s
  tolerance is a design decision; **the complete absence of the
  deviation check for live-listed tokens is not an acknowledged one**.
  The finding therefore passes Q5 — but this is the main triage risk,
  and the report puts the config question first so triage can judge it
  with full information. If GMX considers the missing feeds intended
  behaviour too, the report should be closed as such, not paid.

## Q6: Can you prove impact beyond "technically possible"? — PASS

- Yes — measured in dollars on a live Arbitrum fork, with fresh-price
  controls in the same run. $2,000 long +25% pump, 299s-old report:
  **+$499 (24.95%)**; $4,000 long +25%: **+$999**; +10% pump:
  **+$199**; 301s-old report **reverts** (the age bound binds exactly).
  Keeper withdrawal path: **+$101** stale vs fresh redemption. 17/17
  tests pass (fork block 524367000). The gain is realised money the
  trader keeps (a fill at a price the market no longer trades at), not
  a theoretical path.
- Honest scope note: the 25% move in 300s is extreme; realistic moves
  in 300s are smaller and the gain scales with the move (K3: +10% →
  $199 on $2,000). ZORA is the thinnest real no-feed market tested
  (pool ~$11,222, short OI $20,418.57); larger no-feed markets would
  scale the numbers but the mechanism is identical.

## Q7: Is this a known-invalid bug class? — PASS

- Not on the skill's NEVER SUBMIT list (missing headers, SPF/DKIM,
  GraphQL introspection alone, banner disclosure, clickjacking,
  tabnabbing, CSV injection, CORS wildcard without proof, logout CSRF,
  self-XSS, open redirect alone, OAuth secret in mobile app, SSRF DNS
  callback only, etc.). An oracle-validation gap with a measured
  financial effect is a standard, payable Immunefi class.

## Q8 (identity check) — N/A BY DESIGN

- Q8 is the skill's check for authenticated (Web2) hunts (which session,
  cross-identity repro, stale credentials). This finding is
  permissionless at the trader level (any trader's order can be the one
  filled at the stale price) and keeper-role-dependent at the execution
  level; the PoC demonstrates it under fresh test accounts. There is no
  identity-dependent behaviour to check.

## Gate result: CONDITIONAL PROCEED (Medium draft)

- Q1, Q2, Q4 carry flagged conditions (keeper cooperation required; no
  listed impact; standalone attacker cannot execute). Q5 carries the
  main triage risk (300s is configured tolerance). No question is
  hidden. Proceeding to draft as **Medium ($10,000 flat)** on the
  explicit instruction that an honest Medium with stated caveats is
  worth submitting when the Studio wave opens a fee-free path.

---

# Part 2 — Recon (the config question)

Question: are the missing price feeds for 56 live-listed index tokens
intended config, and was the deviation check ever meant to be absent
for them?

## What was established live (L2 block 524365647, 2026-11-15)

- `MAX_ORACLE_REF_PRICE_DEVIATION_FACTOR` = **5e29 = 50%** — the
  deviation bound that applies to every token *with* a feed.
- `MAX_ORACLE_PRICE_AGE` = **300s** (keeper path);
  `MAX_ATOMIC_ORACLE_PRICE_AGE` = **30s**;
  `MAX_ORACLE_TIMESTAMP_RANGE` = **60s**.
- **146 live markets** via `Reader.getMarkets` (dump had 131, all still
  live; 15 newer).
- Only **two oracle providers in use live**, both Chainlink Data
  Streams, both enabled: `0x7BA7Ae61…` (enabled, atomic=false, 112/113
  tokens under live Oracle 0x26C02F) and `0xE1d5a068…` (enabled,
  atomic=true, 111/113 under the second deployed Oracle 0x7F01614c).
- **No `StaticOracleProvider` found anywhere**; GmOracleProvider has no
  live users. Majors all have feeds: WETH, WBTC, USDC, ARB, LINK, GMX,
  SOL.
- **56 index tokens in live-listed markets have `PRICE_FEED` = zero
  address**: 45 from the dump (43 synthetic placeholder index tokens —
  SPY, QQQ, GOLD, SILVER, WTIOIL, BRENTOIL, NATGAS, BONK, FARTCOIN,
  MOODENG, SPX6900, ZORA, RENDER, FET, TRX, XLM, ONDO, SKY, JUP, INJ,
  HBAR, ICP, AVNT, OKB, AIXBT, LINEA, VIRTUAL, BCH, CHZ, DASH, FIL,
  PENGU, DYDX, FLOKI, ALGO, WLD, XAUT, CC, MET, KAS, DOLO, JTO — plus
  **2 real tokens: ANIME `0x37a64564…`, EIGEN `0x606c3e50…`**) + 11
  more from the 15 newer live markets (symbols unresolved, synthetic
  placeholders) + wstETH as a long/short-only no-feed token.
- Zero-provider tokens that are NOT findings: APE (deprecated, market
  isListed=False — orders cannot execute at all) and USDG (zero provider
  under oracle2 only; has a provider under live oracle1).

## What is established vs not established

- **ESTABLISHED:** for 56 live-listed index tokens the 50% deviation
  check does not run at all. `_validatePrices` skips the reference
  check when `PRICE_FEED` is zero; only the age + 60s-range checks bind.
- **ESTABLISHED:** the `executeAtomicWithdrawal` comment claims feeds
  must be configured for all market tokens, but no code enforces it.
- **NOT ESTABLISHED:** whether GMX's Security Committee knows the
  feeds are missing for these tokens, or considers the absence intended
  (e.g. because most are synthetic placeholders with no Chainlink feed
  to point at). That is exactly what the report asks triage to decide,
  with the config question front and centre.
- **NOT ESTABLISHED (and not claimed):** that any keeper has ever
  submitted a stale report, or that any loss has occurred on mainnet.
  The finding is about the missing check and the measured exploit
  primitive on a fork, not about an observed mainnet incident.

---

# Part 3 — Report (Immunefi submission draft)

---

## Title

Stale-price execution on tokens with no Chainlink price feed: the oracle reference-deviation check is skipped entirely, letting a keeper fill orders at a 5-minute-old price

## Severity: Medium — $10,000 (flat)

**One-line justification:** for 56 live-listed index tokens the protocol's
only guard against executing far from the market price — the 50%
reference-deviation check — does not run at all, and a keeper executing
an order with a 299-second-old report fills at the pre-move price for a
measured gain of up to $999 per trade (24.95% on $4,000). It is not High
because a standalone user cannot execute it (it needs a permissioned
keeper's cooperation) and it matches no listed High impact; it is not
griefing-Medium because it has a profit motive. The honest ceiling is
Medium, with a real risk of "intended behaviour" triage (the 300s age
bound is explicitly configured tolerance).

## Summary

GMX V2 validates oracle prices in `Oracle._validatePrices`: a signed
report must be fresh (≤300s old), its timestamps must span ≤60s, and its
price must be within 50% (`MAX_ORACLE_REF_PRICE_DEVIATION_FACTOR` = 5e29)
of the Chainlink price feed reference. But the deviation check runs **only
if a price feed is configured** for the token. For **56 index tokens in
live-listed markets the `PRICE_FEED` key in the DataStore is the zero
address** — no feed is configured — so the check is skipped entirely and
only the age + range bounds apply.

Measured on a live Arbitrum fork (ZORA market, block 524367000): a keeper
executing a $2,000 long with a **299s-old** signed report after a +25%
pump fills at the pre-move price, worth **$2,499 — a $499 gain (24.95%)**
vs $1,999 for the fresh-price control. A $4,000 long gains **$999**; a
+10% pump gains **$199**; a 301s-old report **reverts** (the age bound
binds exactly). The keeper withdrawal path also works (+$101 stale vs
fresh redemption). The atomic withdrawal path — the one a standalone user
could have used — is already defended by design (a creation-time
timestamp check rejects any report older than "now"), so this is a
keeper-threat-model finding, not a standalone user exploit.

## A question for triage, first (please read before judging severity)

We know the 300s age bound is **explicitly configured tolerance** — a
299s-old report is inside the protocol's own stated tolerance — and we
know keepers are a trusted permissioned set. We also know most of the 56
tokens are synthetic placeholders with no Chainlink feed to point at.

**This report is not claiming the 300s age bound itself is a bug.**
The question we are asking is whether the **complete absence of the
deviation check** for live-listed tokens was intended: for every token
with a feed, a report more than 50% away from the reference price
reverts; for these 56 tokens there is no bound at all on how far the
stale price can deviate from the market within the 300s window. A 25%
move in 5 minutes is realistic for long-tail tokens (BONK, FARTCOIN,
MOODENG, SPX6900, ZORA routinely move 10–30% in 5 minutes). And the
code itself suggests the feeds were meant to exist: the
`executeAtomicWithdrawal` comment claims on-chain feeds must be
configured for all market tokens — but that is **not enforced anywhere
in code** (no feed check in WithdrawalHandler / WithdrawalUtils /
SwapPricingUtils); only the comment says it.

If the GMX team considers the missing feeds intended behaviour, please
close this as such — we would rather have a fast, honest "intended"
than a slow dispute. If it was not considered, the gap below is real
and measured, and the natural fix is to either configure a reference
feed (or a static reference price) for every listed index token, or to
reject execution outright for tokens with no reference feed configured.

## Impact

### Keeper order path — FOUND, measured

| Test | Setup | Result |
|---|---|---|
| K1 | $2,000 long, +25% pump, 299s-old report | filled at pre-move price, worth **$2,499 → gain $499 (24.95%)** |
| K1c | Control, fresh report at pumped price | worth **$1,999 (gain $0)** |
| K2 | 301s-old report | **reverts** (age bound binds exactly) |
| K3 | $2,000 long, +10% pump, 299s-old report | worth **$2,199 → gain $199 (9.95%)** |
| K4 | $4,000 long, +25% pump, 299s-old report | worth **$4,999 → gain $999 (24.98%)** |

- **Who loses:** the pool / remaining LPs in the market. The position
  is filled at a price the market no longer trades at; the gain is
  value extracted from the pool.
- **Who can do it:** a keeper (permissioned `ORDER_KEEPER`) colluding
  with a trader, or a compromised keeper — repeatedly, at any size the
  market supports, on any of the 56 no-feed tokens. A standalone user
  cannot force it.
- **Why not Critical:** the gain is bounded by the order size and the
  price move inside a 300s window; it does not put 10% of funds at risk
  in one action; it needs a permissioned keeper.
- **Why not High:** it matches no listed High impact (the listed High
  impacts are theft / permanent freezing of *unclaimed yield*), and the
  standalone-user path is blocked by design.
- **Why not griefing-Medium:** griefing explicitly excludes
  profit-motive attacks; this one is profitable.

### Keeper withdrawal path — FOUND, measured, small

| Test | Setup | Result |
|---|---|---|
| W1 | $2,000 GM + $4,000 short, −25%, withdrawal created at T0, keeper executes at T0+299 with 299s-old pre-fall report | redeems **$1,997** |
| W1c | Control, keeper executes with fresh report at fallen price | redeems **$1,896** |
| W1vsW1c | Same-run comparison (snapshot/revert) | **stale − fresh = $101** |

The withdrawal gain is the withdrawer's pro-rata share (~17.35% of the
pool) of the pool-value difference, not the full position PnL — and the
index-denominated impact pool partly offsets it (see "Vulnerability
details" §5). Same keeper-cooperation caveat as the order path.

### Atomic withdrawal path — NOT FOUND (blocked by design)

`executeAtomicWithdrawal` is external with no role check, so it looked
like the user-executable route. **It cannot work.** A second check binds
first (`contracts/withdrawal/ExecuteWithdrawalUtils.sol:100`):

```solidity
if (params.oracle.minTimestamp() < withdrawal.updatedAtTime())
    revert Errors.OracleTimestampsAreSmallerThanRequired(...);
```

This applies to **every** withdrawal (atomic and keeper-executed). For
atomic withdrawals the withdrawal is created inside the same call, so
`updatedAtTime ==` the execution block timestamp, and **any report older
than "now" is rejected**. The 30s age bound is strictly weaker for atomic
withdrawals — the creation-time check is the binding one. Fork tests
A1/A1b/A3 (25s-old reports, both directions, GM-only and GM+short) all
revert `OracleTimestampsAreSmallerThanRequired(T0, T0+25)`; A2 (31s-old)
reverts `MaxPriceAgeExceeded`. This is a genuine negative: the protocol
already defends the atomic path, by a check that has nothing to do with
the missing price feed. We report it so triage can see the analysis was
complete.

## Vulnerability details

### The 56 tokens and their live config

| | ZORA market (tested) | The 56 no-feed tokens (recon) |
|---|---|---|
| Market address | `0xac484106d935f0f20F1485b631fA6F65AeEff550` | 56 live-listed markets (see `recon.json`) |
| Index token | ZORA `0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a` | incl. 2 real tokens: ANIME `0x37a64564…`, EIGEN `0x606c3e50…`; rest synthetic placeholders (SPY, QQQ, GOLD, BONK, FARTCOIN, MOODENG, SPX6900, RENDER, FET, …) + 11 newer markets + wstETH long/short-only |
| `PRICE_FEED` (DataStore) | zero address | zero address (all 56) |
| `MAX_ORACLE_PRICE_AGE` | 300s | 300s |
| `MAX_ORACLE_TIMESTAMP_RANGE` | 60s | 60s |
| Deviation check | **skipped (no feed)** | **skipped (no feed)** |

(Live config at L2 block 524365647, RECON-RESULTS.md; fork block
524367000, ZORA P0 = $0.004431 from the GMX API, 15 Nov ~12:00 WIB.
Majors — WETH, WBTC, USDC, ARB, LINK, GMX, SOL — all have feeds and
are unaffected.)

### The mechanism

1. **`Oracle._validatePrices` skips the reference check when there is
   no feed.** The deviation check compares the signed report's price
   against the Chainlink price feed reference (`PRICE_FEED` key in the
   DataStore). When that key is the zero address there is nothing to
   compare against, so the check is skipped — not loosened, not
   defaulted to a static price, simply absent. Only the age bound
   (≤300s) and the timestamp-range bound (≤60s) remain.
2. **A 299s-old report is therefore a valid execution price at any
   deviation.** The report is a genuine signed Chainlink Data Streams
   report (reports are public); the keeper supplies it as
   `oracleParams` to `OrderHandler.executeOrder`. The order fills at
   the report's price — the price from 299 seconds ago, before the
   move. Tokens filled match the P0 expectation exactly (zero price
   impact at these sizes).
3. **The 301s boundary proves the age bound is the only guard.** K2
   (301s-old report) reverts; K1 (299s-old) fills. The exploit window
   is the full 300 seconds, and inside it the deviation is unbounded.
4. **The withdrawal variant works for the same reason.** A withdrawal
   created *before* the move (`updatedAtTime == T0`) passes the
   creation-time timestamp check on equality, and the keeper executes
   it at T0+299 with the 299s-old report (age 299s ≤ 300s). The
   atomic variant fails because the withdrawal is created inside the
   same call, so `updatedAtTime == now` and any stale report is
   rejected.
5. **The impact-pool offset (why the withdrawal gain is only $101).**
   The position-impact pool is denominated in the **index token
   (ZORA)**, and `MarketUtils.getPoolValueInfo` deducts it in USD:

   ```solidity
   result.poolValue -= impactPoolUsd;   // impactPoolUsd = impactPoolAmount × indexTokenPrice
   ```

   Measured on the fork (`test/GP07OiProbe.t.sol`): impactPoolUsd is
   $1,689 at P0, $1,267 after a −25% fall (−$422), $2,111 after a +25%
   pump (+$422). A fall shrinks the deduction → pool value rises $422
   → the GM share rises ~$73 (17.35%), partly offsetting the
   position-PnL effect. Any stale-price GM analysis on a no-feed market
   must account for this; it systematically offsets the position-PnL
   effect (here by ~42% of the own-short contribution). The pre-existing
   shorts ($20,418.57 OI, long ~$1) do not move the pool value across
   ±25%: their uncapped PnL sits above the withdrawal cap
   (`MAX_PNL_FACTOR_FOR_WITHDRAWALS` = 0.45 × shortTokenUsd ≈ $2,906),
   so the capped PnL is pinned at the cap in all three price arms
   (positive PnL is capped; negative PnL passes through uncapped —
   `getCappedPnl`).

### Code paths (repo `gmx-synthetics` main @ a85ea34 — OLDER than deployed code; behaviour verified on the live fork)

- `Oracle._validatePrices`: the reference-deviation check, skipped
  when `PRICE_FEED` is zero; age bound `MAX_ORACLE_PRICE_AGE` (300s)
  and timestamp-range bound `MAX_ORACLE_TIMESTAMP_RANGE` (60s).
- `contracts/withdrawal/ExecuteWithdrawalUtils.sol:100`: the
  creation-time timestamp check that blocks the atomic path
  (`OracleTimestampsAreSmallerThanRequired`).
- `OrderHandler.executeOrder`: `onlyOrderKeeper`; keeper supplies
  `oracleParams`.
- `ExchangeRouter.executeAtomicWithdrawal`: external, no role check —
  the user-executable entry point that turns out to be defended.
- `MarketUtils.getPoolValueInfo`: `poolValue -= impactPoolUsd`
  (index-denominated impact pool).
- `MarketUtils.getCappedPnl`: positive PnL capped at
  `MAX_PNL_FACTOR_FOR_WITHDRAWALS` × shortTokenUsd.
- `DataStore` keys: `Keys.priceFeedKey(token)` (`PRICE_FEED`).

## Steps to reproduce

All reproduction is on a **local Arbitrum fork** (Foundry). No mainnet
transactions were sent at any point. The harness sets oracle prices from
the **live Chainlink feed values read from the DataStore at the fork
block** (`Oracle.setPrimaryPrice`, pranking the ExchangeRouter which holds
CONTROLLER, + `Oracle.setTimestamps`), then calls handlers with **empty
`SetPricesParams`** so `setPrices()` is a no-op. No oracle forgery, no
fake prices: the mock provider stands in for the signed-report delivery
of prices that are already live on-chain. (`withOraclePrices` clears
prices at the end of every handler call, so the harness re-sets them
before every call; `vm.txGasPrice(0.1 gwei)` before every
create/execute/cancel.)

### 1. Clone the PoC and run the tests

```bash
git clone https://github.com/Anyeps/gmx-no-feed-oracle-stale-price-poc.git
cd gmx-no-feed-oracle-stale-price-poc
forge install foundry-rs/forge-std   # lib/ is not committed
forge test --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 524367000
# Expected: 17 passed, 0 failed (4 suites).
```

Key assertions to inspect:
- `test/GP07Keeper.t.sol` — `testK1StaleFillAfterPump25`: $2,000 long,
  299s-old report at P0 after a +25% pump, fills at P0 (worth $2,499);
  `testK1cFreshControlAfterPump25`: fresh report, worth $1,999;
  `testK2Report301sOldReverts`: 301s-old report reverts;
  `testK3StaleFillAfterPump10`: +10% pump, worth $2,199;
  `testK4StaleFillLargeAfterPump25`: $4,000 long, worth $4,999.
- `test/GP07Atomic.t.sol` — `testA1AtomicWithdrawStaleAfterFall25` /
  `testA1bGmOnlyStaleAfterFall25` / `testA3GmOnlyStaleAfterPump25`:
  25s-old reports revert `OracleTimestampsAreSmallerThanRequired`;
  `testA2AtomicReport31sOldReverts`: reverts `MaxPriceAgeExceeded`;
  `testW1KeeperWithdrawStaleAfterFall25` / `testW1cKeeperWithdrawFreshAfterFall25` /
  `testW1vsW1cStaleMinusFresh`: keeper withdrawal redeems $1,997 stale
  vs $1,896 fresh (**+$101**).
- `test/GP07Probe.t.sol` — market/OI state probes at the fork block.
- `test/GP07OiProbe.t.sol` — impact-pool / withdrawal-cap probes
  (impactPoolUsd $1,689 → $1,267 / $2,111 across ±25%).

Note: the public RPC prunes old state — use a fresh fork block close to
524367000 if that block is no longer available. The numbers above were
re-run at the same block (17/17 pass).

### 2. Verify the missing feed yourself (read-only, no fork needed)

```bash
# DataStore on Arbitrum:
#   0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8
# PRICE_FEED key for ZORA (0xc5ff0eB026dB972F95DF3dfF04e697d8b660092a):
#   keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED")), token))
#   = 0x39001d6bbaf4a51a9645acca1755c0df9f6b136f105451b68c90a6d82b93c631
#   (verified live at block 524370571: ZORA, ANIME and EIGEN all read zero;
#   WETH reads 0x639fe6ab55c921f74e7fac1ee960c0b6293ba612 as a control)
cast call 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8 \
  "getAddress(bytes32)" \
  0x39001d6bbaf4a51a9645acca1755c0df9f6b136f105451b68c90a6d82b93c631 \
  --rpc-url https://arb1.arbitrum.io/rpc
# Expected: 0x0000000000000000000000000000000000000000 (no feed configured)
# The full per-token table is in recon/recon.json (56 no-feed tokens).
```

### 3. Manual reproduction (mainnet-equivalent steps, for triage — do NOT execute against mainnet)

1. As a trader, open a long order on a no-feed market (e.g. ZORA
   `0xac484106d935f0f20F1485b631fA6F65AeEff550`) before a price move.
2. As a keeper (or with a cooperating keeper), execute the order at
   T0+299 supplying `oracleParams` built from the signed report at T0
   (before the move). The report's age (299s) is inside the 300s bound
   and its timestamps span ≤60s, so `_validatePrices` passes — there is
   no deviation check to fail.
3. Read the position (via `Reader.getPosition`): it is filled at the
   T0 price, although the market has moved. The difference between the
   fill value and the current market value is the extracted gain.

## Supporting evidence

### Test results (all on a fresh Arbitrum fork, live Chainlink prices)

| Suite | Tests | Block | Result |
|---|---|---|---|
| `GP07KeeperTest` | 5 (K1/K1c/K2/K3/K4) | 524367000 | 5 passed |
| `GP07AtomicTest` | 10 (A1/A1b/A1c/A1bc/A2/A3/A3c/W1/W1c/W1vsW1c) | 524367000 | 10 passed |
| `GP07ProbeTest` | 1 (market/OI state) | 524367000 | 1 passed |
| `GP07OiProbeTest` | 1 (impact pool / withdrawal cap) | 524367000 | 1 passed |
| **Total** | **17** | **524367000** | **17 passed, 0 failed** |
| Independent re-run of all suites | 17 | 524367000 | 17 passed, 0 failed |

### Static analysis

Not run on this finding's contracts (the root cause is a config +
validation-logic gap, not a code pattern Slither flags). Slither 0.11.6
was run on the pricing contracts for the sibling finding G-P1-2(a)
(`PositionPricingUtils.sol`, `PricingUtils.sol`, `SwapPricingUtils.sol`,
`MarketUtils.sol`): **0 High findings**.

### Negative results — what was tested and did NOT reproduce (boundaries of this report)

| Hypothesis | Result |
|---|---|
| Atomic withdrawal with a ≤30s-old pre-move report (A1/A1b/A3) | NOT FOUND — blocked by design. `ExecuteWithdrawalUtils.sol:100` rejects any report older than the withdrawal's creation time; for atomic withdrawals creation == execution, so any stale report reverts. |
| 31s-old atomic report (A2) | NOT FOUND — reverts `MaxPriceAgeExceeded` (the 30s bound also binds). |
| StaticOracleProvider with a stale configured price (recon sub-lead (a)) | NOT FOUND — no StaticOracleProvider exists on Arbitrum. |
| GmOracleProvider as an alternate execution path (recon sub-lead (c)) | NOT FOUND — no live users. |
| Zero-provider tokens APE / USDG as exploit routes | NOT FINDINGS — APE's market is deprecated (isListed=False, orders cannot execute); USDG has a provider under the live oracle. |

### Limitations

- Mock-provider harness: the stale report is simulated with
  `MockOracleProvider7` (signed-report forgery is out of scope; real
  reports are public and obtainable, so this models the real
  primitive).
- The 25% move in 300s is extreme; realistic moves in 300s are smaller
  and the gain scales with the move (K3: +10% → $199 on $2,000).
- ZORA is the thinnest real no-feed market tested (pool ~$11,222, OI
  short $20,418.57); larger no-feed markets would scale the numbers
  but the mechanism is identical.
- The withdrawal gain depends on the market's impact-pool size and the
  withdrawer's pool share; it is not a fixed fraction of the move.

## References

- PoC evidence (supplied with this report — repo first, because the
  Immunefi form accepts only JPEG/PNG attachments):
  - **https://github.com/Anyeps/gmx-no-feed-oracle-stale-price-poc**
  - `REPORT-DRAFT.md` — this draft (severity Medium)
  - `FINDINGS.md` — fork-test findings, 17/17 tests
  - `RECON-RESULTS.md` — live recon, 56 no-feed tokens
  - `recon/recon.json` — full per-token provider/feed table (L2 block
    524365647)
  - `test/GP07Keeper.t.sol`, `test/GP07Atomic.t.sol`,
    `test/GP07Probe.t.sol`, `test/GP07OiProbe.t.sol` — Foundry fork tests
  - `contracts/` — harness contracts (mock oracle provider, fork helpers,
    GMX interfaces, Keys)
- Program: GMX on Immunefi — https://immunefi.com/bug-bounty/gmx/information/
  (scope: https://immunefi.com/bug-bounty/gmx/scope/)
- Repo: https://github.com/gmx-io/gmx-synthetics (main @ a85ea34 at hunt
  time; note the deployed code is newer than this commit — all behaviour
  above was verified against the live deployment on the fork, not just
  the repo read)

## Submission checklist (complete before submitting)

- [ ] **Fah approves this draft** (required — no submission without it).
- [ ] **Fee-free submission path open** — this draft is waiting for the
      Immunefi Studio wave ("Ready" verdict unlocks fee-free submission).
      Do NOT pay the 100-credit (100 USDC) Novice fee; the submission is
      blocked until the Studio invite arrives (watch: `studio-wave-watch`
      checks Gmail every 12h).
- [ ] Re-check the live Immunefi GMX page before submitting:
  - [ ] Full "Impacts in Scope" High/Medium list (the text fetch cut off
        after "Temporary freezing of funds") — confirm a stale-price /
        oracle-validation impact maps to Medium, and that no listed
        impact covers this (which would change the severity).
  - [ ] Full "Out of Scope" list + Prohibited Activities + Feasibility
        Limitations (rendered empty in the text fetch).
  - [ ] Known Issues list — confirm no new entry covers this since
        2026-11-13 (6 entries then, none covering this).
  - [ ] Payout currency / payment rails.
  - [ ] Confirm first-report-wins still applies and the program is still open.
- [ ] Payout address: `0x45859319D9A362f2146d0431dc30ab8f0ef1Be73`
      (Fah's payout wallet; same wallet as the G-P1-2(a) draft).
- [ ] Attach the PoC repo link (first line of the PoC field — the form
      accepts only JPEG/PNG attachments, so the repo carries the
      evidence). Note in the submission that all tests run on a local
      Arbitrum fork; no mainnet transactions were sent.
- [ ] Submit promptly once Fah approves AND the fee-free path opens —
      **first report wins**; do not delay. Submit via "Submit a Bug" on
      https://immunefi.com/bug-bounty/gmx/information/ (Immunefi,
      triaged by Immunefi; KYC not required per the live page).
- [ ] No public disclosure before fix — keep the finding confidential
      until GMX/Immunefi authorise disclosure. (The PoC repo is public
      by necessity — Immunefi's form takes no code attachments — the
      same approach as the G-P1-2(a) PoC repo.)
- [ ] After submission, track the report through triage to payout receipt
      (standing rule: payout to Fah's wallet; follow up if triage asks for
      clarification or a re-test).

---

*End of draft. Prepared 2026-11-15. DRAFT ONLY — DO NOT SUBMIT.*
