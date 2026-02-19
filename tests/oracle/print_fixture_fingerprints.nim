import std/[os, strformat]
import ../support/oracle_harness

proc main() =
  let thisDir = currentSourcePath().parentDir
  let repoRoot = thisDir.parentDir.parentDir
  let manifestPath = repoRoot / "tests" / "oracle" / "fixtures.json"
  let fixtures = loadOracleFixtures(manifestPath)

  for fx in fixtures:
    let fastqAbs = repoRoot / fx.fastqPath
    let fp = fingerprintFastqPath(fastqAbs)
    echo fmt"{fx.id}: records={fp.records} fingerprint={fp.fingerprint}"

main()

