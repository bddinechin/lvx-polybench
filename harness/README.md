# PolyBench as a compiler-performance tracker for LVX

```bash
./harness/run.sh                            # lvx-2, -O2, MINI, float AND double
ARCH=lvx-1 OPT=3 ./harness/run.sh
DATASET=SMALL ./harness/run.sh
TYPE=float ./harness/run.sh                 # just one width
STATIC_ONLY=1 ./harness/run.sh              # build + static metrics, minutes
ONLY='gemm syrk 2mm' ./harness/run.sh       # a subset
LVX_CPU=minor ./harness/run.sh              # pipeline model, much slower

./harness/make-reference.sh                 # regenerate the x86 oracle
./harness/fpcompare.sh                      # 32-bit vs 64-bit FP, side by side
./harness/compare.sh results/A.tsv results/B.tsv
```

Results land in `results/<arch>-O<opt>-<dataset>-<type>.tsv`, one row per kernel.
Commit them: the series is the point, and `compare.sh` diffs two of them.

## Both FP widths, every time

`TYPE` is a **list** and defaults to `float double`, because on this machine the
two are not alternative settings of one benchmark — together they *are* the
measurement. An LVX SIMD lane group is 128 bits wide whatever it holds, so a
float vector is four lanes and a double vector two. A kernel the vectorizer
handles should therefore run its float version close to **2× faster** than its
double version; one left scalar runs them at the **same speed**, because scalar
f32 and f64 cost the same here.

So `fpcompare.sh`'s speedup column is not a property of the ISA. It is a
read-out of the compiler, and the kernels sitting at 1.00× are the work list.

## Why the headline number is the guest's own, not gem5's

PolyBench brackets the kernel and nothing else between
`polybench_start_instruments` and `polybench_stop_instruments`, and on LVX that
reads **`$frcc`**, the 64-bit free-running cycle counter (SRS 63) — patched in
where x86's `RDTSC` was. So the guest itself prints the cycle count of the
*kernel*, with allocation, array initialisation and `printf` excluded.

That matters more than it sounds. gem5's `system.cpu.numCycles` covers the whole
program, and at `MINI` the whole program is mostly not the kernel: for `gemm`,
109,316 kernel cycles sit inside 208,020 total. Tracking the gem5 figure would
mean tracking `crt0` and `malloc` at roughly 50% weight — a real kernel
improvement would be halved before it showed up, and a regression in newlib
would read as a compiler regression.

Both are recorded. `kernel_cycles` is what a compiler change should move;
`prog_cycles` is the cross-check — if one moves and the other does not, suspect
the measurement before the compiler.

This is the one respect in which PolyBench is a better instrument here than
`lvx-mibench`, which has only whole-program numbers.

## Why cycles, not time

The ISS is **deterministic**: the same ELF yields the same counts every run, on
any host, with no quiet-machine ritual and no averaging. That makes it a better
instrument for tracking a compiler than real hardware. Six metrics per kernel:

| metric | from | what moves it |
|---|---|---|
| `kernel_cycles` | guest `$frcc` delta | **the headline** — the kernel alone |
| `prog_cycles` | gem5 `system.cpu.numCycles` | whole program; the cross-check |
| `bundles_dyn` | gem5 `simInsts` | gem5 counts one **bundle** as one "instruction" on this VLIW, so `prog_cycles / bundles_dyn` is execution-weighted packing density — what scheduling and bundling changes move |
| `text_bytes` | `lvx-mbr-size` | code size |
| `insns_static` | `objdump -d` | instruction count |
| `bundles_static` | `;;` count in the disassembly | static packing |

The static three cost nothing and are defined even for a kernel the ISS cannot
finish, so a code-size or packing regression is caught for all 30 regardless.

**Caveat on what a cycle means.** The default `LVX_CPU=atomic` charges one cycle
per bundle and models no memory latency, so these are really bundle counts — the
right thing for tracking bundling and scheduling, and not a number real hardware
would produce. `LVX_CPU=minor` runs the pipeline model with L1 caches for the
honest measurement; it is much slower and has not been swept yet.

## Why every run is diffed, and why the oracle is generated

**A miscompile can look like a large speed-up.** On this target it has: a stale
`libgcc` object — `divv.o` built against an older binutils, holding eight
instructions whose encodings had since changed — made a `gemm` prototype produce
wrong results while still running to completion and exiting 0.

PolyBench ships no reference output, unlike MiBench. What it ships instead is
better: `POLYBENCH_DUMP_ARRAYS`, which prints every result array in a fixed
format, and **kernels that read no input at all** — each `init_array` fills from
its own index arithmetic. So the oracle is *generated*, by compiling the same
source natively on x86 and keeping its dump (`make-reference.sh`). It is
reproducible rather than archival, and it can be produced for a dataset size or
data type upstream never published.

### The three verdicts, and why a tolerant compare is still a gate

The reference is built `-ffp-contract=off`; the LVX side is **not**, because
`ffma` is the instruction worth measuring. So the two differ by real FMA
rounding on every multiply-accumulate kernel, which is most of them.

| verdict | meaning |
|---|---|
| `ok` | byte-identical to the x86 reference |
| `fp-N` | N printed values differ, **each by at most one unit in the last printed place** |
| `fp-contract` | more than that — but the LVX build is byte-identical to the reference once rebuilt `-ffp-contract=off`, so the code generation is verified and the divergence is FMA rounding the kernel amplifies |
| `MISMATCH` | a real failure, in both builds. Investigate before reading any number in the row |
| `noref`, `exitN`, `timeout`, `buildfail` | did not complete or has no reference |

What keeps `fp-N` from degenerating into "close enough" is that it is derived
from the **print format**, not guessed. PolyBench prints through
`DATA_PRINTF_MODIFIER`, which is `"%0.2f"`/`"%0.2lf"` — two decimals. A 1-ulp
difference is invisible at that precision unless a value sits exactly on a
rounding boundary, so contraction shows up as a handful of values moved by
exactly 0.01 and nothing else. A miscompile moves values by orders of magnitude,
produces `nan`/`inf`, or changes how many values there are.

`fp-contract` is an **escalation, not a whitelist**, and it earns its keep.
`gramschmidt` needs it: classical Gram-Schmidt in float subtracts nearly-equal
projections and normalises by a norm approaching zero, so **448 of its 1516
printed values differ, with sign flips**, purely because LVX emits five
`ffma`/`ffms` where x86 GCC (even `-mfma -ffp-contract=on`) emits none. Rather
than whitelisting the kernel, the harness *proves* it: rebuild exactly the way
the reference was built, and compare again. Bit-exact ⇒ `fp-contract`. Still
different ⇒ `MISMATCH` stands. A real miscompile fails both ways, so this cannot
launder one, and the extra run is only paid when the strict compare already
failed.

## Traps this harness is built around

Three are inherited from `lvx-mibench` and cost a debugging round each there;
two are PolyBench's own. All five are in `GAPS.md` in full.

**gem5's stdout and stderr must not be merged.** gem5's `info:`/`warn:` go to
stderr — including `Increasing stack size by one page`, emitted repeatedly
*mid-run* — while stdout carries only its banner and the guest's bytes. A
`2>&1` interleaves diagnostics into the guest's output and no extraction
recovers it.

**gem5's own redirection cannot separate them instead.** `process.output` has no
effect, because LVX's syscalls are implemented inline in the runtime shim and
bypass gem5's `SyscallDesc` table and its `FDArray` entirely. Hence
`guest-output.py`, which cuts the guest's bytes out positionally.

**The guest's stdin must always be redirected**, even though no PolyBench kernel
reads any. gem5 inherits the harness's stdin, and the harness's stdin is
`utilities/benchmark_list` being read by the loop — so without `< /dev/null` the
guest eats the rest of the list and the sweep stops early.

**`POLYBENCH_DUMP_TARGET` is patched to `stdout` on LVX.** Upstream dumps to
stderr, which is exactly the stream that cannot be trusted here. The dump prints
a whole array with no newline until the end, so a mid-line intrusion is not at a
line boundary and no line-prefix filter can recover it. Measured: 2 gem5
diagnostic lines sat inside the dump before this change.

**`-DPOLYBENCH_CYCLE_ACCURATE_TIMER` alone used to print nothing.** Upstream
gates the timer macros on `POLYBENCH_TIME || POLYBENCH_GFLOPS` and leaves
`POLYBENCH_CYCLE_ACCURATE_TIMER` out, so it selected the cycle counter and then
discarded it — no number, no error. `polybench.h` is patched so it implies the
timer. `GAPS.md` §5.

## Adding a kernel

Nothing to do: the runner reads upstream's own `utilities/benchmark_list`, so a
kernel added there is picked up. Regenerate the reference afterwards.

That is the other way PolyBench is easier than MiBench, which needs a
`benchmarks.def` line carrying sources, arguments, stdin and a reference path —
because its benchmarks take input and these do not.

## Why MINI is the default

`MINI` runs each kernel in ~10^5 kernel cycles, so a full 30-kernel sweep at
both FP widths is minutes, not hours — fast enough to run per commit, which is
what a tracker has to be. `SMALL` and up are correct and available; they are
the right choice for a one-off investigation of cache behaviour under
`LVX_CPU=minor`, not for a series.

The cost is that at `MINI` the loop trip counts are small, so vectorization
overhead (peeling, remainder loops) is a larger share than it would be at scale,
and a few kernels show a float version *slower* than its double version. Read
the ratio as a direction, and confirm anything surprising at `SMALL`.

## What is not here yet

- **The pipeline model across the suite.** `LVX_CPU=minor` is the honest cycle
  count; everything committed so far is the atomic CPU. See the caveat above.
- **A staleness check.** The stale-`divv.o` miscompile that motivated this port
  was invisible to the build. A `stat` comparison of the installed toolchain
  against the ISS binary belongs here and in `validation/`.
- **`-O3` and `-Ofast` series.** Only `-O2` has been swept.
