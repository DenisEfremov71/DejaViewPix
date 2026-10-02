# Evals

`cases.json` holds 30 search queries, each with the search Claude should run for it. The
expected answers were written on 2026-10-02, before any eval run. Day 7 adds the runner
(`swift run evals`); Day 8 uses it to improve the prompt and compare models.

## What is scored

The eval scores **the arguments Claude passes to `search_photos`**, not the photos that come
back. A test library would need thousands of labelled photos to check results. The
arguments can be checked against an answer written by hand, and if they're right, PhotoKit
returns the right photos. The photo library and the geocoder are deterministic code with
their own unit tests; the model's interpretation of the query is what varies.

### Which call is scored

- **The first `search_photos` call that passed input validation** is Claude's reading of
  the query. Later calls (a retry with a wider range after an empty result, which the system
  prompt allows) aren't scored, and they don't count against the case either.
- A call that failed validation (bad date format, half a location) costs nothing directly,
  but if no valid call follows, the case fails.

### Fields

Each case expects five fields. Every field is scored on its own (per-field accuracy), and a
case is an **exact match** only when all five pass, along with the behavior check.

| Field | Matches when |
|---|---|
| `dates` | `date_from` and `date_to` each equal the expected day, give or take `tolerance_days` (default 0). `null` means the call must have no date filter. A `null` end means that end must be absent. |
| `place` | The call's `latitude`/`longitude` is within `within_km` (default 25 km) of the expected point. The radius isn't scored: it comes from `geocode_place`, which is our code. `null` means no location filter. |
| `media_type` | Equal after mapping `"any"` and absent to `null`. |
| `favorites_only` | Equal, with absent meaning `false`. |
| `album` | Equal after trimming, case-insensitive. `null` means no album filter. |

Any field can be `{"one_of": [...]}` to accept several answers. A case can override
`today`, `time_zone` and `within_km`; the defaults are at the top of `cases.json`.

### Behavior

| `behavior` | Passes when |
|---|---|
| `search` (default) | A valid `search_photos` call exists, and the loop ends with `present_results`. |
| `no_photos` | No photos are presented. Not searching is fine; if Claude does search, the first valid call must match `expect`. |
| `no_search` | No `search_photos` call, and no photos presented. The loop may end with an empty `present_results` or with the clean `.noAnswer` error. A crash, a timeout or any other error fails. |

## Matching rules, decided up front

- **Dates are exact by default.** The system prompt defines seasons (winter is
  December–February, "last winter" is the most recent one that has ended), so a season has
  one right answer. `tolerance_days: 1` is used only where people disagree about the edges:
  holidays ("two Christmases ago" could include Christmas Eve), "last weekend", "the past
  two weeks".
- **Places are compared by coordinates, not strings.** "Whistler, BC" and "Whistler, British
  Columbia, Canada" are the same place; "Paris" in Texas is not. 25 km covers any sensible
  geocode of a city; states and regions get a wider `within_km`.
- **"Photos" and "pictures" are generic.** People say them for their whole library, so
  `media_type` may be `null` or `"photo"`. "Videos" is specific and must be `"video"`.
- **Extra filters are wrong.** The system prompt says "only set filters the user asked
  for", so a date range or media type nobody asked for fails that field.
- **Ambiguous places: the user's context decides when it can.** "Victoria" means Victoria,
  BC for a user in America/Vancouver and the state of Victoria for a user in
  Australia/Melbourne; only that reading passes. When nothing in the context picks one
  ("Springfield"), any of the main candidates passes, because a reasonable person couldn't
  do better without asking.
- **The time zone decides the hemisphere** when no place is named (`rel-07`: "last summer"
  from Sydney is December–February). The current system prompt only says the *place*
  decides, so this case may fail at first. That's deliberate: it's an expectation of what's
  right, not of what the prompt currently says.

## How the cases were chosen

- **One query per idea, not per phrasing.** Each case tests a different way the reading
  could go wrong: date arithmetic, season boundaries, hemisphere, holidays, misspellings,
  ambiguous places, filter combinations, albums (user and smart), favorites, impossible
  dates, out-of-scope requests and prompt injection. There are no near-duplicates, so a
  fix can't pass several cases at once by memorizing one phrasing.
- **The same query under different contexts** (`rel-02`/`rel-03`, `amb-01`/`amb-02`,
  `rel-01`/`rel-07`) shows whether the model uses `today` and the time zone, rather than
  having learned one answer.
- **A fixed "today"** (Friday 2026-10-02, America/Vancouver, unless a case overrides it),
  so the expected dates never go stale.
- **Real places and albums from the seed set:** Whistler, Vancouver, Squamish, Tofino and
  Paris match `scripts/seed-simulator-photos.swift`. The Day 7 fake library must have a user
  album "Hiking" and smart albums "Screenshots" and "Selfies", and should filter its canned
  photos by the query, so impossible dates return nothing.
- **Weighted toward dates.** 8 of the 30 cases are relative dates, the most common query
  type and where models get the arithmetic wrong.
- **Known before writing:** during the Day 4 and 5 checks, "photos from Whistler last
  winter" and "my favorite videos" were run live. Haiku once answered last winter as
  December 2024–February 2025. The expected answers here come from the definitions above,
  not from those runs.

## Test split

Five cases are marked `"split": "test"`: `simple-05`, `rel-06`, `typo-03`, `combo-03` and
`album-03`, one from each of five categories. **They aren't used while tuning.** The runner
skips them unless asked to include them, and they are run once, at the end of Day 8, to
check that the gains on the 25 dev cases are real.

## Running

```sh
cd AlbumAI
ANTHROPIC_API_KEY=… swift run evals                # 25 dev cases × 2 runs on Haiku
swift run evals --model sonnet --runs 3            # another model, more runs
swift run evals --case rel-07 --runs 5             # one case
swift run evals --split test                       # the held-back cases: only at the end of Day 8
```

- The key comes from `ANTHROPIC_API_KEY`, never from the app's Keychain. To keep it out of
  shell history, store it once in the macOS login keychain
  (`security add-generic-password -a "$USER" -s anthropic-api-key-evals -w`, which prompts for
  it) and run `ANTHROPIC_API_KEY=$(security find-generic-password -a "$USER" -s
  anthropic-api-key-evals -w) swift run evals`.
- Each case runs through the real tool loop and the real API, with a canned photo library
  (`EvalKit/CannedLibrary.swift`) and Apple's geocoder, cached per run. A case **passes**
  only if every run passes; one pass and one fail is **flaky**.
- Results go to `evals/results/<date>-<time>-<model>-<split>.{json,md}`. The JSON has every
  run's observed arguments, so failures can be read without running again. The prompt
  fingerprint changes whenever the system prompt or a tool definition changes.
- `swift test` never calls the API. The scoring rules have their own offline tests in
  `Tests/EvalKitTests`.
