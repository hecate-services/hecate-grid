# hecate-grid

**A TSO open-data sensor.** It polls near-real-time electricity grid datasets and
publishes each response, byte for byte, onto the mesh for
[hecate-archive](https://codeberg.org/hecate-services/hecate-archive) to keep.

Same shape as [hecate-warden](https://codeberg.org/hecate-services/hecate-warden) and
[hecate-news](https://codeberg.org/hecate-services/hecate-news): observe the world,
publish facts, hold no store.

## What it watches

Elia (Belgium) by default, near-real-time only. The set is chosen so that
**measurement and the operator's own forecast of the same quantity** are both captured.

| Dataset | What | Cadence | Polled |
|---|---|---|---|
| `ods161` | Imbalance price, per minute | 1 min | 60 s |
| `ods169` | Current system imbalance, with components | 1 min | 60 s |
| `ods136` | Elia's imbalance forecast, current quarter-hour | ~1 min | 60 s |
| `ods147` | Elia's imbalance forecast, next quarter-hour | ~1 min | 60 s |
| `ods002` | Total load: measured **and** day-ahead/most-recent forecast with P10/P90 | 15 min | 5 min |
| `ods086` | Wind: realtime estimate **and** forecasts, per region | 15 min | 5 min |
| `ods087` | Solar: realtime estimate **and** forecasts, per region | 15 min | 5 min |

The forecast datasets are the point, not padding. A published operator forecast is a
**graded benchmark, for free**: a model that cannot beat it has not earned attention,
and that is knowable on day one rather than after a month of compute. A stream that
publishes its own forecast is worth more than a stream with ten times the resolution.

Other TSOs fit the same shape and are a config change, not a code change: Elexon
Insights (GB, no key, richer), Fingrid (FI), ENTSO-E (EU-wide, token by email).

## What it does not do

**It does not parse.** What goes on the wire is the bytes Elia returned. Not a scaled
number, not a picked field, not a tidied record.

Two reasons pointing the same way:

- **Correctness.** An ingest that is wrong produces a record that is wrong *and
  internally consistent*, and no later analysis can find the error. Keep the bytes and a
  parser bug is a re-run; keep only the parse and it is a retraction.
- **Lightness.** Not parsing is less work. The correct choice and the cheap choice are
  the same choice.

**It does not hold a store.** No reckon-db, no disk, no read model. The only state is a
sequence number per dataset, in memory, scoped to this run by an `epoch` so that a
restart is visible *as a restart* rather than mistaken for missing data.

## How it avoids lying

**Overlapping windows.** Each poll asks for several intervals' worth of the most recent
rows, so a missed poll is recovered by the next one. The tape therefore contains
duplicate *rows* across consecutive records, and that is correct: de-duplicating by
event time is the replay parser's job, where it can be re-done. Dropping the overlap
here would be interpretation, and it could not be undone.

**Non-200 responses are published, not swallowed.** A gap in the archive must be
distinguishable from an outage at the source, and both from our own crash. This matters
more than it sounds: feeds die *because* of the event of interest, and an archive that
drops errors encodes "nothing happened" precisely when everything did.

**A failed connection does not advance the sequence.** If nothing came back at all there
is nothing to archive, and claiming a gap would be a false report about the mesh rather
than a true one about the source.

**The first poll waits for the mesh.** `hecate_om` connects asynchronously, so a poll
fired at boot would publish into a dark mesh (a no-op) while consuming sequence numbers,
manufacturing a gap out of our own impatience.

**Per-source intervals.** A quarter-hourly dataset polled every minute is fifteen
identical answers and fourteen wasted requests, landing on a free public service that
can be lost by being abused.

## Volume

Measured, not guessed: one `ods161` row is ~324 bytes of JSON and a request round-trips
in ~340 ms. The default seven-dataset set is about **13 MB/day** of raw payload, under
2 MB/day once the archive gzips it at seal.

## Configuration

| Variable | Default | What |
|---|---|---|
| `HECATE_GRID_SOURCES` | (the table above) | `source\|dataset\|base_url\|limit\|poll_ms`, comma-separated. Elia caps `limit` at 100. |
| `HECATE_GRID_POLL_MS` | `60000` | Fallback interval for a source that carries none. |
| `HECATE_GRID_TOPIC` | `archive/observations` | Must match the archive's topic. |
| `HECATE_SENSOR_REF` | `unset` | Git sha of this build, stamped on every record. Left unset, the tape is not attributable to a build and the sensor says so loudly at boot. CI sets it. |
| `HECATE_REALM` | (required) | Must match the archive's realm. |
| `HECATE_HEALTH_PORT` | `8481` | `/health`. |

## Attribution

Grid data by [Elia](https://www.elia.be/en/grid-data/open-data), published as open data.

## Build

```sh
rebar3 compile
rebar3 lint
rebar3 as prod release
```
