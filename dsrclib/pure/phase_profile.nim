## Optional phase timing helpers for pure-Nim encode/decode profiling.
## Enable with: DSRCLIB_PROFILE_PHASES=1

import std/[monotimes, os, strutils, times]

type
  PhaseStamp* = MonoTime

var phaseProfileCache {.threadvar.}: int8
var phaseProfileInitialized {.threadvar.}: bool

proc phaseProfileEnabled*(): bool =
  if not phaseProfileInitialized:
    let raw = getEnv("DSRCLIB_PROFILE_PHASES", "")
    if raw.len == 0:
      phaseProfileCache = 0
    else:
      let v = raw.toLowerAscii()
      phaseProfileCache = int8(v == "1" or v == "true" or v == "yes" or v == "on")
    phaseProfileInitialized = true
  phaseProfileCache == 1

proc phaseNow*(): PhaseStamp {.inline.} =
  getMonoTime()

proc phaseElapsedMs*(start: PhaseStamp): float64 {.inline.} =
  inNanoseconds(getMonoTime() - start).float64 / 1_000_000.0

proc fmtMs*(ms: float64): string {.inline.} =
  formatFloat(ms, ffDecimal, 3)
