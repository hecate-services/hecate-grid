# Changelog

All notable changes to `hecate-grid` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-24

### Added
- First cut of the TSO open-data sensor: polls Elia near-real-time datasets and
  publishes each response verbatim as an `observation` fact.
- Default source set pairs measurement with Elia's own published forecast
  (`ods161`, `ods169`, `ods136`, `ods147`, `ods002`, `ods086`, `ods087`), so a
  graded external benchmark comes with the data.
- Per-source poll intervals and overlap-sized row limits, so a missed poll is
  recovered by the next one without hammering a free public service.
- Non-200 responses are published rather than swallowed, so an upstream outage is
  distinguishable from a hole in the tape.
- `epoch` + `seq` on every record, so a restart is visible as a restart and the
  sensor can stay storeless.
