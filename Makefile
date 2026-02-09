NIM ?= nim
NIMFLAGS = -d:release --opt:speed --path:. --passC:-march=native
BINDIR = bin
EXAMPLES = fastq2dsrc undsrc

TARGETS = $(addprefix $(BINDIR)/, $(EXAMPLES))

INPUT_GZ = tests/data/large.fastq.gz
BENCHDIR = benchmark

.PHONY: all clean bench

all: $(TARGETS)

$(BINDIR):
	mkdir -p $(BINDIR)

$(BINDIR)/fastq2dsrc: example/fastq2dsrc.nim dsrclib.nim dsrclib/dsrc_bindings.nim | $(BINDIR)
	$(NIM) c $(NIMFLAGS) --out:$@ example/fastq2dsrc.nim

$(BINDIR)/undsrc: example/undsrc.nim dsrclib.nim dsrclib/dsrc_bindings.nim | $(BINDIR)
	$(NIM) c $(NIMFLAGS) --out:$@ example/undsrc.nim

bench: $(TARGETS)
	@mkdir -p $(BENCHDIR)
	$(eval TMPDIR := $(shell mktemp -d))
	@echo "=== Decompressing $(INPUT_GZ) to $(TMPDIR)/test.fastq ==="
	gunzip -c $(INPUT_GZ) > $(TMPDIR)/test.fastq
	@echo ""
	@echo "=== Compress: 1 thread ==="
	hyperfine \
		"dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compress_1thread.csv \
		--export-markdown $(BENCHDIR)/compress_1thread.md
	@echo ""
	@echo "=== Compress: 4 threads ==="
	hyperfine \
		"dsrc c -t4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compress_4threads.csv \
		--export-markdown $(BENCHDIR)/compress_4threads.md
	@echo ""
	@echo "--- Preparing DSRC file for decompression benchmarks ---"
	dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc
	@echo ""
	@echo "=== Decompress: 1 thread ==="
	hyperfine \
		"dsrc d -t1 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 1 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompress_1thread.csv \
		--export-markdown $(BENCHDIR)/decompress_1thread.md
	@echo ""
	@echo "=== Decompress: 4 threads ==="
	hyperfine \
		"dsrc d -t4 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 4 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompress_4threads.csv \
		--export-markdown $(BENCHDIR)/decompress_4threads.md
	@echo ""
	@echo "=== Cleaning up temp dir ==="
	rm -rf $(TMPDIR)
	@echo "Results saved to $(BENCHDIR)/"

clean:
	rm -rf $(BINDIR)
