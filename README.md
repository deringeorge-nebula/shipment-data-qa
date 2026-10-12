# Shipment Data QA in SQL

Nine data-quality checks for container shipment and vessel tracking data, written in PostgreSQL, and scored against faults I planted myself so their accuracy can be measured rather than assumed.

**Result:** all 59 planted faults caught, zero false alarms, and five mutation tests showing each check fires on a fault it has never seen.

> **The data is synthetic.** It is generated with a fixed seed, so anyone can rebuild it, and every planted fault is recorded so detection can be scored row by row. Vessel names and IMO numbers start with `SYN` / `9000` so they cannot be confused with real ships. Port coordinates are real but approximate.

---

## Why this project

A tracking platform is only as good as the data under it. A duplicated milestone, a time-zone slip or a speed sent in the wrong unit will quietly corrupt every delay prediction built on top. I wanted to show I can find those faults, trace each to its cause, and prove the checks work rather than say they do.

The idea comes from my own projects, where the most expensive bugs were data faults that looked plausible: a speed column labelled knots that was really m/s, and satellite images that showed 7% of a tidal flat as wet in one collection and 75% in another, because an offset had been applied twice.

## What it checks

| Check | What it catches | How |
| --- | --- | --- |
| `DUPLICATE_EVENT` | A milestone delivered twice | Group by shipment, event and time |
| `OUT_OF_ORDER` | Milestones going backwards in time (e.g. ARRIVED before DEPARTED) | Window function over the milestone sequence |
| `EVENT_AFTER_RECEIPT` | A record received before the event it reports (clock or time-zone error) | Compare event time with receipt time, 5 min tolerance |
| `MISSING_MILESTONE` | A milestone absent although a later one arrived | Anti-join against the milestone list |
| `UNKNOWN_LOCATION` | A port code that does not exist | Anti-join against the UN/LOCODE table |
| `BAD_CONTAINER_NO` | A container number with a wrong check digit | ISO 6346 check digit, implemented in SQL |
| `POSITION_JUMP` | A GPS glitch | Haversine distance: impossible speed (> 35 kn) both into and out of the point |
| `SPEED_UNIT_MS` | Speed sent in m/s but labelled knots | Median reported speed ÷ median speed implied by positions ≈ 0.51 |
| `AIS_GAP` | Missing positions | More than 6 h between reports (normal: 3 h) |

## Results

### Detection, scored row by row against the planted faults

| Check | Planted | Caught | Missed | False alarms |
| --- | ---: | ---: | ---: | ---: |
| AIS_GAP | 5 | 5 | 0 | 0 |
| BAD_CONTAINER_NO | 5 | 5 | 0 | 0 |
| DUPLICATE_EVENT | 12 | 12 | 0 | 0 |
| EVENT_AFTER_RECEIPT | 6 | 6 | 0 | 0 |
| MISSING_MILESTONE | 8 | 8 | 0 | 0 |
| OUT_OF_ORDER | 8 | 8 | 0 | 0 |
| POSITION_JUMP | 6 | 6 | 0 | 0 |
| SPEED_UNIT_MS | 3 | 3 | 0 | 0 |
| UNKNOWN_LOCATION | 6 | 6 | 0 | 0 |

Matching is on the exact record, not on counts: a check that found 12 duplicates in the wrong 12 places would score zero.

Sample findings, as the checks report them:

```
SPEED_UNIT_MS  voyage 89      reported 8.6 kn vs implied 16.9 kn (ratio 0.510)
POSITION_JUMP  9000011        at 2026-02-04 12:32 UTC: 87.8 kn in, 75.8 kn out
AIS_GAP        voyage 50      no position from 2026-01-31 12:30 to 2026-02-01 06:30 (18:00:00)
BAD_CONTAINER_NO              SYBU0005391: check digit should be 0
```

The speed-unit ratio of 0.510–0.519 is the unit conversion itself (1 kn = 0.514 m/s), recovered from the data alone.

### Does the analysis tell the truth?

The analysis runs only on the 623 of 668 shipments that passed every check. Because the data is synthetic, I know what the true answers are, so I can test whether the queries recover them.

ETA predictions were generated with a 3% optimistic bias on the remaining voyage time. The query recovers it:

| Predicted at | Mean error (h) | Mean absolute error (h) | 90th percentile (h) |
| --- | ---: | ---: | ---: |
| Departure | −2.76 | 6.86 | 16.80 |
| 25% of voyage | −2.20 | 4.98 | 11.60 |
| 50% of voyage | −1.35 | 3.35 | 8.46 |
| 75% of voyage | −0.68 | 1.69 | 3.77 |

The planted bias at departure is −2.93 h; the query measures −2.76 h, within one standard error (≈ 0.31 h).

**What not to read into these numbers.** Carriers were assigned at random, so the differences between carriers in delay and in findings per 100 shipments are noise, not findings. The value here is the method and the checks, not the synthetic statistics.

## How it is tested

`sql/06_tests.sql` stops with an error naming any test that fails:

1. **Functions against known answers:** the ISO 6346 textbook example (`CSQU3054383`), and one degree of latitude = 60 nautical miles.
2. **Scorecard:** every planted fault caught, no false alarms, and no faulty shipment in the analysis set.
3. **Mutation tests:** five new faults planted one at a time inside a sub-transaction. Each must raise its check's count by exactly one; then the change is rolled back and the scorecard re-checked.

I also broke checks on purpose to confirm the tests notice:

| Deliberate break | Test result |
| --- | --- |
| Position-jump threshold raised to 500 kn (check goes blind) | `FAIL scorecard POSITION_JUMP: 6 missed` |
| Gap threshold lowered to 2 h (check fires on clean data) | `FAIL scorecard AIS_GAP: 8813 false alarms` |

## What went wrong while building it

- **A function that only worked by accident.** `container_no_is_valid` called another function without its schema name, so it worked only when the session's search path included `shipqa`. The first scorecard run failed on this. Supabase's SQL editor uses a different search path, so it would have failed there too. Fixed by schema-qualifying the call; the tests now run with no search path set.
- **A wasteful join.** The first port-dwell query joined two sets of shipments to the ports table at once, which multiplied rows. The averages happened to come out right, but only because every row was repeated equally. Rewritten as two separate aggregates.

## Run it yourself

**Supabase (no install):** open the SQL editor, paste `supabase_all_in_one.sql`, run. It ends with a table of six PASS rows. Then run the queries in `sql/05_analysis.sql` one at a time.

**Any PostgreSQL 14+:**

```bash
psql -f sql/01_schema.sql -f sql/02_generate_data.sql -f sql/03_qa_checks.sql \
     -f sql/04_scorecard.sql -f sql/06_tests.sql
psql -f sql/05_analysis.sql
```

Everything lives in its own schema, `shipqa`, and re-running drops and rebuilds it. The exact numbers can differ slightly between PostgreSQL versions; the tests pass either way.

## Files

| File | What it does |
| --- | --- |
| `sql/01_schema.sql` | Tables, ports, vessels, haversine and ISO 6346 functions |
| `sql/02_generate_data.sql` | 268 voyages, 668 shipments, 4,012 events, 9,318 positions, then 59 planted faults |
| `sql/03_qa_checks.sql` | The nine checks, one view each |
| `sql/04_scorecard.sql` | Row-by-row comparison with the planted faults |
| `sql/05_analysis.sql` | Delays, ETA accuracy, transit times, port dwell, feed latency |
| `sql/06_tests.sql` | Function, scorecard and mutation tests |
| `supabase_all_in_one.sql` | Files 01–04 and 06 joined, for one paste |
| `results/` | Output of the run reported above |

## About

Built by **Derin George M A**, final-year Naval Architecture & Ship Building, Indian Maritime University. I set the goal and the standard (every check scored against known faults), ran every file, checked every result, and can explain every query.

Contact: deringeorge6@gmail.com · Preprint: [doi.org/10.31223/X59B8P](https://doi.org/10.31223/X59B8P)
