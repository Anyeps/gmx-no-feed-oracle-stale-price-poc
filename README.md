# GMX — Stale-price execution on tokens with no Chainlink price feed (PoC)

**Finding:** for 56 index tokens in live-listed GMX V2 markets, the
`PRICE_FEED` key in the DataStore is the zero address — no Chainlink price
feed is configured — so `Oracle._validatePrices` skips the 50%
reference-deviation check entirely. Only the 300s age bound and the 60s
timestamp-range bound apply. A keeper executing an order with a 299s-old
signed report fills at the pre-move price.

**Measured (local Arbitrum fork, block 524367000):** a $2,000 ZORA long
opened after a +25% pump fills at the pre-move price — **gain $499
(24.95%)** vs $0 for the fresh-price control. $4,000 long → **+$999**;
+10% pump → **+$199**; a 301s-old report **reverts** (the age bound binds
exactly). Keeper withdrawal path: **+$101** stale vs fresh redemption.
The atomic withdrawal path — the one a standalone user could have used —
is blocked by design (`ExecuteWithdrawalUtils.sol:100` rejects any report
older than the withdrawal's creation time).

**Severity argued: Medium ($10,000 flat).** The finding matches no listed
Immunefi impact at any severity (not unclaimed-yield theft/freezing, not
griefing — it has a profit motive), and the keeper path needs a
permissioned keeper's cooperation — the same bar G-P0-1 failed on, except
here there is NO deviation check at all to be inside of. The 300s age
bound is explicitly configured tolerance, so "intended behaviour" is a
real triage outcome; the draft states it plainly. See `REPORT-DRAFT.md`
for the full 7-question gate and the config question for triage.

## Files

- `REPORT-DRAFT.md` — full report draft (severity Medium), incl. the
  7-question gate, the config question, and the submission checklist.
- `FINDINGS.md` — fork-test findings, 17/17 tests.
- `RECON-RESULTS.md` — live recon: 56 no-feed tokens (45 from the dump —
  43 synthetic placeholders + 2 real: ANIME, EIGEN — + 11 newer markets +
  wstETH long/short-only). No StaticOracleProvider anywhere; majors all
  have feeds.
- `recon/recon.json` — full per-token provider/feed table (L2 block
  524365647); `recon/analysis.txt`, `recon/live_markets.json`.
- `test/GP07Keeper.t.sol` — keeper order path (K1/K1c/K2/K3/K4, 5/5).
- `test/GP07Atomic.t.sol` — atomic path negative + keeper withdrawal
  (A1/A1b/A1c/A1bc/A2/A3/A3c/W1/W1c/W1vsW1c, 10/10).
- `test/GP07Probe.t.sol`, `test/GP07OiProbe.t.sol` — market/OI/impact-pool
  probes.
- `contracts/` — harness contracts (mock oracle provider, fork helpers,
  GMX interfaces, Keys).

## Reproduce

```bash
forge install foundry-rs/forge-std   # lib/ is not committed
forge test --fork-url https://arb1.arbitrum.io/rpc --fork-block-number 524367000
# Expected: 17 passed, 0 failed (4 suites).
```

Note: the public RPC prunes old state — use a fresh fork block close to
524367000 if that block is no longer available. The harness sets primary
prices via `Oracle.setPrimaryPrice` (pranked as ExchangeRouter) with
`Oracle.setTimestamps(now, now)`, then executes orders with empty
`SetPricesParams`. See `FINDINGS.md` for the full gotcha list.

## Status

Draft ready, NOT submitted. Submission is blocked by the 100-credit
(100 USDC) Novice fee and waits for the Immunefi Studio wave. This repo
is linked from the report because Immunefi's submission form accepts only
JPEG/PNG attachments.
