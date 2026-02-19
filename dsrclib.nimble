# Package
version       = "0.2.0"
author        = "Andrea Telatin"
description   = "Read DSRC2 compressed FASTQ files"
license       = "GPL-2.0"
skipDirs      = @["tests"]
backend       = "cpp"
srcDir        = "./"
binDir        = "bin"
bin           = @["undsrc", "fastq2dsrc"]

# Dependencies
requires "nim >= 2.0.0", "readfx >= 0.2.0"
