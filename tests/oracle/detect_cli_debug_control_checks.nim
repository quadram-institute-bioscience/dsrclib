import std/[os, strutils]
import ../support/oracle_harness

proc main() =
  if getEnv("DSRCLIB_DSRC_CMD", "").strip().len == 0:
    let mambaExe = getEnv("MAMBA_EXE", "")
    if mambaExe.len > 0:
      putEnv("DSRCLIB_DSRC_CMD", "XDG_CACHE_HOME=/tmp " & quoteShell(mambaExe) & " run -n base dsrc")
    else:
      putEnv("DSRCLIB_DSRC_CMD", "XDG_CACHE_HOME=/tmp micromamba run -n base dsrc")

  if not hasDsrcCli():
    stderr.writeLine("dsrc CLI not available")
    quit(2)

  let tmpDir =
    if paramCount() >= 1: paramStr(1)
    else: getTempDir() / "dsrclib_oracle_harness"

  let enabled = dsrcCliUsesDebugControlChecks(tmpDir)
  echo "debug_control_checks=", (if enabled: "1" else: "0")

main()
