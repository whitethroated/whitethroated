# Isolation attempt: Swift-internal /json RPS deficit

Date: 2026-10-17. Host: Apple M1 Pro, macOS. Verdict: **INCONCLUSIVE —
measurement window polluted by host-side load; no conclusion for or
against a real deficit.**

## Question

The matched `/json` matrix showed framework-vs-raw RPS at 91–96%,
systematic across 8 of 9 rounds. Head-cache-miss was ruled out by
reading. This run isolated prepared-vs-dynamic and empty-vs-body:
raw × {`/`, `/prepared`, `/json`} and framework × {`/`, `/prepared`,
`/plaintext`, `/json`}, c64/c256, RPS-only, median of 3 rounds,
42 cells, zero shortfalls. Byte parity verified first: framework
`/prepared` == raw `/prepared` == framework `/plaintext` (identical
13-byte + date response); `/` identical empty responses.

## Data (median, rounds in brackets)

- raw / c64: 138998 [126737 144167 138998]
- raw / c256: 147672 [150275 147672 144693]
- raw /prepared c64: 138173 [140528 138173 116258]
- raw /prepared c256: 143727 [147439 143727 118700]
- raw /json c64: 139518 [139518 141625 83217]
- raw /json c256: 145625 [145625 147111 143411]
- framework / c64: 138869 [142263 138869 131326]
- framework / c256: 134149 [145966 128535 134149]
- framework /prepared c64: 123553 [138927 117629 123553]
- framework /prepared c256: 133848 [142055 133848 129284]
- framework /plaintext c64: 137795 [137795 138670 132419]
- framework /plaintext c256: 141610 [141610 143442 136260]
- framework /json c64: 137055 [138447 137055 135040]
- framework /json c256: 138106 [141600 138106 121844]

Framework-vs-raw medians: `/` 99.9/90.8%, `/prepared` 89.4/93.1%,
`/json` 98.2/94.8%. Six of fourteen cells contain a round dipping
>10% below the cell max (worst: raw `/json` c64 R3 at 83217, −41%).

## Why inconclusive

1. **The control fails.** Framework-vs-raw on `/` — the known-good
   route whose gates passed — reads −9.2% at c256 in this window.
   Any 2–9% effect is therefore unresolvable here.
2. **Identified polluters, not hand-waving.** During/after the run:
   only ~96 MB free memory (`vm.memory_pressure` nonzero, 5847 free
   16K pages), load averages 6.6–9.7 on 8 cores, a ChatGPT/Codex
   renderer process at 231% CPU, and a `tar` job at 49%. These are
   user-side processes and were left untouched.
3. **Fixed server order confounds small gaps.** Raw always ran before
   framework within each round while the machine degraded over the
   run (broad R1→R3 decline on both servers), biasing framework cells
   downward by an amount comparable to the observed 2–9% gaps. The
   same confound applies to the earlier `/json` matrix (raw →
   runtime → framework → hono → express); it cannot explain the
   35–126% competitor gaps but can explain small Swift-internal ones.
4. One clean data point exists and is weak: in round 1 (the quietest
   round), framework `/prepared` ≈ `/plaintext` (−0.5%/−0.3%),
   suggesting no prepared-vs-dynamic cost — but n=1 round proves
   nothing.

## Standing

The prior `/json` deficit (−4 to −9%, clean window) is neither
confirmed nor refuted. The deficit question remains open.

## Strengthened protocol for the re-run (do not re-run blind)

1. Pre-flight machine check: substantial free memory, load well below
   core count, no CPU-hog user processes; abort the matrix if the
   window degrades mid-run.
2. Rotate server order per round (raw-first / framework-first
   alternating) to cancel time-trend bias.
3. Five rounds instead of three for any claim under 10%.
4. Keep the route-interleaved single-uptime design (routes × conns
   inside one server start); it worked.
5. Re-run in a quiet window only — a degraded window produces
   systematic-looking small gaps that waste analysis time, as here.

## Attempt 2 (same day, strengthened protocol): route-specific small cost

Rotated server order per round (odd raw-first, even framework-first),
5 rounds, quieter window (memory pressure 0, load ~3 falling, hogs
gone). 70/70 cells, zero shortfalls. Medians-of-5, rounds in brackets:

- raw / c64: 134561 [143633 134561 142907 132752 125056]
- raw / c256: 142568 [147282 130987 146387 142568 115485]
- raw /prepared c64: 139050 [141228 139050 140995 136359 133136]
- raw /prepared c256: 143863 [144624 144451 139965 143863 142704]
- raw /json c64: 141593 [141593 141771 140267 143071 131634]
- raw /json c256: 145231 [145231 145441 144874 138596 147110]
- framework / c64: 134404 [137824 123826 131552 134404 145240]
- framework / c256: 138027 [138027 145500 129402 129786 148752]
- framework /prepared c64: 132960 [132960 137337 125587 125099 139872]
- framework /prepared c256: 132441 [140230 119833 132441 125644 143413]
- framework /plaintext c64: 132679 [136820 128473 132679 111139 140301]
- framework /plaintext c256: 134034 [135633 107199 134034 132345 142833]
- framework /json c64: 122992 [116783 121085 122992 134852 138033]
- framework /json c256: 134854 [114293 122011 134854 141634 143550]

Framework-vs-raw: `/` 99.9/96.8%, `/prepared` 95.6/92.1%, `/json`
86.9/92.9% (c64 median lands on dip-clustered rounds — ascending
R1→R5 shows early dips + late clean runs, treat as unreliable point).
Framework wins 8/30 rounds overall with no order effect (3/12 when
running first vs 5/18 when second — rotation canceled order bias as
designed, and the direction persists regardless of order).

Findings:

1. Empty responses at parity: control `/` reads 99.9/96.8%.
   Window validated for effects above ~4%.
2. Prepared-vs-dynamic parity on identical bytes: framework
   `/plaintext` vs `/prepared` within ±1.2% (medians) with heavily
   overlapping rounds. Per-request dynamic response construction is
   exonerated (5 rounds, same-server, interleaved).
3. Small body-response deficit, order-independent: framework trails
   raw ~2–8% on `/prepared` and `/json` across three independent
   matrices (base, `/json`, isolation ×2). Triangulation: the base
   report's own worst cells were already body routes (framework-vs-
   runtime 98.5% on `/user/42` c64; framework-vs-raw band bottom
   97.5%).
4. Mechanism (read, not guessed): `PreparedResponse` already
   precomputes its body buffer once and shares it, and conversion is
   shallow struct/CoW copies — the residual is dispatch + conversion
   object work (~2–5%, at this apparatus's resolution limit in
   current noise). No large effect exists anywhere; nothing exceeds
   10% outside dip artifacts.

Verdict: standing small cost, NOT a regression (predates `/json`,
predates this campaign's benchmark-only changes; base gates stand).
Optional future lead only: trimming per-request dispatch/conversion
on the prepared-body path has ~2–4% upside on body routes, provable
only in quiet windows with the rotated 5-round protocol. Not
recommended ahead of the tail-latency campaign (low EV).
