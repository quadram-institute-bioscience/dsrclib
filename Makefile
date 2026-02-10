NIM ?= nim
NIMFLAGS = -d:danger --gc:arc --opt:speed --path:. --passC:-march=native
BINDIR = bin
EXAMPLES = fastq2dsrc undsrc

TARGETS = $(addprefix $(BINDIR)/, $(EXAMPLES))

INPUT_GZ =  tests/data/large.fastq.gz
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
	@echo "=== Compression: single thread ==="
	hyperfine \
		"dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compression_single.csv \
		--export-markdown $(BENCHDIR)/compression_single.md
	@echo ""
	@echo "=== Compression: threaded (4 threads) ==="
	hyperfine \
		"dsrc c -t4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc1" \
		"$(BINDIR)/fastq2dsrc -t 4 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc2" \
		--prepare "rm -f $(TMPDIR)/test.dsrc1 $(TMPDIR)/test.dsrc2" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/compression_threaded.csv \
		--export-markdown $(BENCHDIR)/compression_threaded.md
	@echo ""
	@echo "--- Preparing DSRC file for decompression benchmarks ---"
	dsrc c -t1 $(TMPDIR)/test.fastq $(TMPDIR)/test.dsrc
	@echo ""
	@echo "=== Decompression: single thread ==="
	hyperfine \
		"dsrc d -t1 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 1 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompression_single.csv \
		--export-markdown $(BENCHDIR)/decompression_single.md
	@echo ""
	@echo "=== Decompression: threaded (4 threads) ==="
	hyperfine \
		"dsrc d -t4 $(TMPDIR)/test.dsrc $(TMPDIR)/out1.fastq" \
		"$(BINDIR)/undsrc -t 4 $(TMPDIR)/test.dsrc $(TMPDIR)/out2.fastq" \
		--prepare "rm -f $(TMPDIR)/out1.fastq $(TMPDIR)/out2.fastq" \
		--warmup 1 \
		--export-csv $(BENCHDIR)/decompression_threaded.csv \
		--export-markdown $(BENCHDIR)/decompression_threaded.md
	@echo ""
	@echo "=== Cleaning up temp dir ==="
	rm -rf $(TMPDIR)
	@echo "Results saved to $(BENCHDIR)/"
	@echo ""
	@echo "=== Analysing results ==="
	python3 $(BENCHDIR)/bench_summary.py

clean:
	rm -rf $(BINDIR)
