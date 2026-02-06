## dsrclib — Read DSRC2 compressed FASTQ files
##
## Provides a readfx-compatible iterator for reading .dsrc2 files.
##
## Usage:
##   import dsrclib
##   for rec in readDSRC("reads.dsrc2"):
##     echo rec.name, " ", rec.sequence.len

import readfx
import dsrclib/dsrc_bindings

export readfx
export dsrc_bindings

proc splitTag(tag: string): tuple[name: string, comment: string] =
  # DSRC's tag field includes the '@' prefix from the FASTQ header line.
  # ReadFX strips it, so we do the same.
  var t = tag
  if t.len > 0 and t[0] == '@':
    t = t[1 .. ^1]
  let spacePos = t.find(' ')
  if spacePos == -1:
    result = (t, "")
  else:
    result = (t[0 ..< spacePos], t[spacePos + 1 .. ^1])

iterator readDSRC*(path: string): FQRecord =
  ## Read FASTQ records from a DSRC2 compressed file.
  ## Yields readfx-compatible FQRecord objects.
  var archive = newDsrcArchive()
  var cppRec = newCppFastqRecord()
  try:
    archive.startDecompress(path.cstring)
    while archive.readNextRecord(cppRec):
      let tag = $cppRec.getTag()
      let (name, comment) = splitTag(tag)
      yield FQRecord(
        name: name,
        comment: comment,
        sequence: $cppRec.getSequence(),
        quality: $cppRec.getQuality()
      )
    archive.finishDecompress()
  except CatchableError:
    try: archive.finishDecompress()
    except CatchableError: discard
    raise

proc decompressDSRC*(inputPath, outputPath: string) =
  ## Decompress a .dsrc2 file to a .fastq file.
  ## Uses DsrcModule for maximum performance (multi-threaded).
  var module = newDsrcModule()
  module.decompress(inputPath.cstring, outputPath.cstring)
