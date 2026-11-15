# G-P0-7 — Recon results (live, 15 Nov 2026 ~11:45 WIB)

## 0. Decode bug — diagnosed and fixed

`recon.py` first failed with `web3 BadFunctionCallOutput / NonEmptyPaddingBytes:
Boolean must be either 0x0 or 0x1. Got: b' '`. Root cause, proven empirically:
the contract at Multicall3's canonical address
`0xcA11bde05977b3631167028862bE2a173976CA11` on Arbitrum One answers
`aggregate` with the **Multicall v1/v2 layout `(uint256, bytes[])`**, NOT
Multicall3's `(uint256, (bool,bytes)[])`. Raw return decodes cleanly as
`(uint256, bytes[])` and yields correct values (MAX_REF_DEV = 5e29,
WETH provider = 0x7BA7Ae61...). The old ABI made eth_abi read a
bytes-length word (0x20) as a bool.

Fix in `recon.py`: raw `eth_call` + manual `eth_abi.decode(["uint256",
"bytes[]"])`, with per-item length validation. No new dependencies.
Also recorded: `block.number` inside the EVM on Arbitrum is the **L1 height**
(~26,418,084) while `eth_blockNumber` is the L2 height (~524,365,647);
`recon.json` records both.

## 1. Live values (L2 block 524,365,647)

- `MAX_ORACLE_REF_PRICE_DEVIATION_FACTOR` = **5e29 = 0.5 (50%)** — confirms G-P0-1.
- `MAX_ORACLE_PRICE_AGE` = **300s** (keeper path); `MAX_ATOMIC_ORACLE_PRICE_AGE` = **30s**; `MAX_ORACLE_TIMESTAMP_RANGE` = **60s**.
- Live on-chain markets via `Reader.getMarkets`: **146** (dump had 131, all still live; 15 newer).
- Only **two providers in use live**, both Chainlink Data Streams, both enabled:
  - `0x7BA7Ae61…` — enabled, atomic=false (112/113 tokens under live Oracle 0x26C02F)
  - `0xE1d5a068…` — enabled, atomic=true (111/113 under deployments Oracle 0x7F01614c)
- Both candidate Oracle addresses have code. **0x26C02F is the live order-execution
  Oracle** (proven by G-P0-1/G-P0-2 forks); 0x7F01614c is a second deployed Oracle
  (its provider is the atomic one).
- **No StaticOracleProvider found anywhere**; GmOracleProvider has no live users.
  Sub-lead (a)/(c) dead on Arbitrum.
- Majors all have feeds: WETH, WBTC, USDC (both), ARB, LINK, GMX, SOL — YES.

## 2. The finding (sub-lead (b) confirmed at config level)

**56 index tokens in LIVE-listed markets have NO Chainlink price feed**
(`PRICE_FEED` key = zero address), so `_validatePrices` skips the 50%
reference-deviation check entirely for them. Only the age + 60s-range checks bind.

- 45 from the 131-market dump (43 synthetic placeholder index tokens with no
  code — SPY, QQQ, GOLD, SILVER, WTIOIL, BRENTOIL, NATGAS, BONK, FARTCOIN,
  MOODENG, SPX6900, ZORA, RENDER, FET, TRX, XLM, ONDO, SKY, JUP, INJ, HBAR,
  ICP, AVNT, OKB, AIXBT, LINEA, VIRTUAL, BCH, CHZ, DASH, FIL, PENGU, DYDX,
  FLOKI, ALGO, WLD, XAUT, CC, MET, KAS, DOLO, JTO + 2 real tokens: **ANIME,
  EIGEN**) + 1 long/short-only no-feed token (**wstETH**, long token in
  ETH/USD [wstETH-USDe] and SWAP-ONLY [wstETH-ETH]).
- 11 more from the 15 newer live markets (index tokens, symbols unresolved —
  synthetic placeholders): 0x2cd2eb61…, 0x3eea56a1…, 0xaf770f03…, 0x5503cf72…,
  0xbb69bd9d…, 0x1f3407ea…, 0xd1738d37…, 0x4249f6e0…, 0x465a31e5…,
  0x96ee343e…, 0xe7304e9f….

## 3. Zero-provider tokens (not a finding)

- `0x74885b4d…` APE (deprecated): zero provider under BOTH oracles; market
  isListed=False (deprecated). Orders can't execute at all — not exploitable.
- `0x004b5068…` USDG: zero provider under oracle2 only; has a provider under
  live oracle1. Not an issue.

## 4. Exploitability — two paths, read from Oracle.sol

**Keeper path (orders via OrderHandler):** age ≤300s, range ≤60s, NO deviation
cap for the 56 tokens. A 299s-old signed report captures the full 5-minute
move — long-tail tokens (BONK/FARTCOIN/MOODENG/SPX6900/ZORA) routinely move
10–30% in 5 min. BUT execution needs a keeper to submit the stale report;
keepers submit fresh reports (same caveat as G-P0-1, where +5% was NOT FOUND).
Difference vs G-P0-1: there the gain was *inside* the 50% configured tolerance;
here there IS no configured tolerance to be inside of.

**Atomic path (user-executable, no keeper):** `ExchangeRouter.executeAtomicWithdrawal`
is `external payable nonReentrant` with NO role check — any user calls it for
their own withdrawal, supplying their own `oracleParams`. Validation is
`_validatePrices(..., forAtomicAction=true)`: provider must be the enabled
atomic provider (0xE1d5a068), age **≤30s**, range ≤60s, ref check only if a
feed exists. So a ≤30s-old pre-move report is usable by the user directly —
but only for WITHDRAWALS (the only atomic action; no atomic swap/order exists),
only within a 30s window, and only if the user already holds GM in that market
(redemption value depends on the stale index price). Also note: the
`executeAtomicWithdrawal` comment claims feeds must be configured for all market
tokens — **that is NOT enforced anywhere in code** (no feed check in
WithdrawalHandler/WithdrawalUtils/SwapPricingUtils); only the comment says it.

## 5. Verdict

**FOUND at recon/config level — fork test warranted, NOT yet a reportable finding.**

- The decision rules' NOT FOUND condition ("every listed token maps to the
  Data Streams provider AND has a feed") is FALSE: 56 live-listed index tokens
  have no feed.
- The FOUND condition's second clause ("a token with no price feed where a
  signed report can move execution price materially") is met at config level but
  explicitly requires a fork test showing a profitable fill.
- Fork test (RECON-NOTES.md plan, adapted): fresh Arbitrum fork, G-P0-1
  mock-provider harness pattern. (1) Keeper path: no-feed market (suggest ZORA
  — real token, market 0xac484106…, already exercised in G-P0-5 — or BONK),
  299s-old report from before a simulated move vs fresh control; measure fill
  advantage. (2) Atomic path: executeAtomicWithdrawal with a ≤30s-old pre-move
  report while holding GM; measure redemption vs fresh control. Record the
  keeper-cooperation caveat for (1) explicitly — it is the same bar G-P0-1
  failed on, minus the tolerance argument.

## Files

- `recon.py` (fixed), `recon.json` (L2 block 524365647), `live_markets.json`,
  `analysis.txt` (full per-token dump), this file.
