# Oracle Harness

This directory contains the verification harness used to keep the DSRC pure-Nim port measurable at each step.

## Files

- `fixtures.json`: fixture manifest with expected record counts and logical fingerprints
- `fixtures/edge_cases.fastq`: synthetic edge-case FASTQ fixture
- `print_fixture_fingerprints.nim`: helper to recompute fixture fingerprints
- `diff_fastq_logical.nim`: logical FASTQ diff tool (record/field-level)
- `detect_cli_debug_control_checks.nim`: probe whether DSRC CLI emits debug control-check markers
- `../support/oracle_harness.nim`: reusable harness library used by tests

## Main test

The main oracle test is:

- `/Users/telatina/git/dsrc-project/dsrclib/tests/test_oracle_harness.nim`

It validates:

1. Fixture integrity (`FASTQ` and optional `DSRC` match expected fingerprints)
2. CLI encode matrix (when CLI is available):
   - pure encode -> CLI decode
   - CLI encode -> pure decode
   - modes: plain/truncated/RLE, order branches, lossy/lossless
3. Optional legacy C++ fixture cross-compat checks (env-gated)
4. Record-level diffs on mismatches for actionable debugging

By default, CLI cross-compat checks are skipped if `dsrc` is not found.
Set `DSRCLIB_ORACLE_REQUIRE_CLI=1` to make missing `dsrc` fail the test.
Use `DSRCLIB_DSRC_CMD` to override CLI command
(for example `XDG_CACHE_HOME=/tmp /opt/homebrew/bin/micromamba run -n base dsrc`).
Legacy fixture checks are disabled by default; enable with
`DSRCLIB_ORACLE_RUN_LEGACY_CLI_COMPAT=1` or require strict pass with
`DSRCLIB_ORACLE_REQUIRE_LEGACY_CLI_COMPAT=1`.
Pure ST-operator checks (forcing `compressDSRC/decompressDSRC` through
the default `threads=1` pure-Nim single-thread path) are required by default
when CLI checks run.
Disable only if needed with `DSRCLIB_ORACLE_REQUIRE_PURE_ST_OPERATOR=0`.
Pure MT-operator checks (forcing the default `threads=2` pure-Nim multi-thread
path in `--threads:on` builds) are also required by default; disable only if
needed with `DSRCLIB_ORACLE_REQUIRE_PURE_MT_OPERATOR=0`.
Pure MT stress/determinism checks are also required by default in
`--threads:on` builds; disable only if needed with
`DSRCLIB_ORACLE_REQUIRE_PURE_MT_STRESS=0`.
Stress tuning env vars:
- `DSRCLIB_ORACLE_MT_STRESS_ROUNDS` (default `2`, minimum `2`)
- `DSRCLIB_ORACLE_MT_STRESS_REPEAT` (default `4`)
- `DSRCLIB_ORACLE_MT_MAX_SEC_PER_RUN` (default `120`)
- `DSRCLIB_ORACLE_MT_MIN_ENCODE_MIBPS` (default `0`, disabled)
- `DSRCLIB_ORACLE_MT_MIN_DECODE_MIBPS` (default `0`, disabled)
- `DSRCLIB_ORACLE_MT_MAX_HEAP_MIB` (default `0`, disabled; Nim heap only)
When needed for debug-built DSRC CLIs, the harness automatically sets
`DSRCLIB_PURE_DEBUG_CONTROL_CHECKS=1` for pure operator encode paths
used by ST/MT cross-compat checks.
Legacy ST checks remain optional, require a `-d:dsrclibLegacy` build,
and run with `DSRCLIB_FORCE_LEGACY_ST_OPERATOR=1`.

## Usage

Recompute fixture fingerprints after fixture changes:

```bash
nim cpp --path:. -r tests/oracle/print_fixture_fingerprints.nim
```

Run logical FASTQ diff:

```bash
nim cpp --path:. -r tests/oracle/diff_fastq_logical.nim -- expected.fastq actual.fastq
```

Detect if DSRC CLI was built with debug control-check markers:

```bash
nim cpp --path:. -r tests/oracle/detect_cli_debug_control_checks.nim
# output: debug_control_checks=1 (debug build) or debug_control_checks=0 (release build)
```
