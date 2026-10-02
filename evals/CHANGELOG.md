# Eval changelog

One change at a time. Each line shows the change, the score before and after on the 25 dev
cases (2 runs each, exact-match rate over runs), and whether it was kept. Results are in
`evals/results/`.

| # | Change | Before → after | Kept? | Results |
|---|---|---|---|---|
| 0 | Baseline: Day 4 prompt | 76.0% (19 pass / 0 flaky / 6 fail) | – | `2026-10-02-1519-haiku-dev` |
| 1 | System prompt lists the computed date ranges of the most recent completed season of each kind, for both hemispheres | 76.0% → 92.0% (23 / 0 / 2) | **Kept**: fixed all 4 wrong-year season cases (`rel-01`, `rel-07`, `typo-01`, `combo-01`); +$0.0003 per query | `2026-10-02-1526-haiku-dev` |
| 2 | Rule: a named day (Christmas, New Year's Day) means that date ± a day, not the whole month, unless the user asks for a wider period | 92.0% → 94.0% (23 / 1 / 1) | **Kept**: fixed `rel-04` in both runs. `rel-07` turned flaky (the hemisphere gap fixed by change 3) | `2026-10-02-1527-haiku-dev` |
| 3 | Seasons follow the hemisphere of the place named or, if none, of the user's time zone (was: of the place only) | 94.0% → 96.0% (23 / 2 / 0) | **Kept**: `rel-07` passes both runs. `amb-02` flaked once (picked Victoria, BC) and `amb-03` searched once | `2026-10-02-1528-haiku-dev` |
| 4 | Rule: the user can't answer questions; for an ambiguous place pick the one the time zone points to, else the best-known, and say which in the summary | 96.0% → 98.0% (24 / 1 / 0) | **Kept**: `amb-02` passes both runs. `amb-03` still declines to guess in 1 of 2 runs | `2026-10-02-1529-haiku-dev` |

Stopped there: the only remaining miss is one run of one genuinely ambiguous case, and with
2 runs per case a single run is 2 points of noise. Another rule aimed at Springfield would
be fitting the dataset, not the users.

Every change is a general rule about dates or places, not about a specific query. None
mentions Whistler, Sydney, Springfield or any other case's wording.

## Model comparison (final prompt `6c1c47fd3a50`)

| Model | Dev exact match (25 × 2) | Held-back (5 × 2) | Latency avg / p95 (dev) | Cost per query (dev) | Results |
|---|---|---|---|---|---|
| Haiku 4.5 (`claude-haiku-4-5-20251001`) | 98.0% (24 / 1 / 0) | 100% (5 / 0 / 0) | 3.52 s / 4.76 s | $0.0066 | `2026-10-02-1529-haiku-dev`, `2026-10-02-1531-haiku-test` |
| Sonnet 5.5 (`claude-sonnet-5-5`) | 100.0% (25 / 0 / 0) | 100% (5 / 0 / 0) | 5.14 s / 8.61 s | $0.0156 | `2026-10-02-1531-sonnet-dev`, `2026-10-02-1531-sonnet-test` |

**Decision: ship Haiku.** Haiku hits 98% at $0.0066 per query, and Sonnet hits 100% at
$0.0156. The 2-point gap is one run of the Springfield case, where neither answer is wrong
for the user. In exchange, Haiku costs 2.4× less and its p95 latency is almost 4 seconds
lower, which the user feels on every search. Sonnet would be worth it if a larger dataset
showed a real accuracy gap on common queries; this one doesn't.

**Held-back check:** both models pass all 5 held-back cases on both runs. There is no
baseline-prompt run on them, so this shows the tuned prompt holds on unseen phrasings (holiday
ranges, misspellings, smart albums) rather than measuring the size of the gain. Five cases
is a small sample.

**What the improvements cost:** input tokens went from 4684 to 5319 per Haiku query (+14%)
because of the longer system prompt. That's about $0.0006 per query, and prompt caching of
the system prompt and tools would recover most of it.
