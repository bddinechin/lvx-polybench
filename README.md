# lvx-polybench

PolyBench/C 4.2.1-beta, imported for LVX and wired up as a
**compiler-performance tracker**: 30 numerical kernels, each timed with the
machine's own cycle counter and each checked against a generated reference
before its number is believed.

- `ORIGIN.md` — provenance, and why the first commit is unmodified upstream
- `GAPS.md` — the six things porting PolyBench to LVX required, measured
- `harness/README.md` — how to run it, and why it measures what it measures
- `results/` — committed TSV series, one row per kernel
- `reference-output/` — the x86-generated correctness oracle

## Quick start

```bash
./harness/run.sh                        # lvx-2, -O2, MINI, float AND double
./harness/fpcompare.sh                  # 32- vs 64-bit FP side by side
./harness/compare.sh results/A.tsv results/B.tsv
```

A sweep is minutes. `make-reference.sh` regenerates the oracle; it is committed,
so a normal run does not need it.

## Why this suite, next to `lvx-mibench`

The two answer different questions and neither replaces the other.

`lvx-mibench` is **integer, control-flow-heavy, real application code** — jpeg,
ispell, blowfish, dijkstra — and what it exercises is the C library, the ABI,
`argv`, string handling, and the long tail of things an embedded program does.
It is the portability and realism check.

PolyBench is **dense floating-point loop nests and nothing else**: affine loops
over arrays, no input, no I/O, no system calls. That makes it the instrument for
the one thing MiBench cannot isolate — *did the vectorizer and the scheduler do
their job* — and it is far easier to run under an ISS. All 30 kernels build and
run on both cores at both FP widths; the port needed six changes, all of them in
PolyBench's own instrumentation and none in newlib, gem5 or the compiler.

Two properties make it unusually well suited here:

**The kernel is timed, not the program.** PolyBench brackets the kernel between
`polybench_start_instruments`/`polybench_stop_instruments`, which on LVX read
`$frcc` — the 64-bit free-running cycle counter, where x86's `RDTSC` was. So the
guest prints the kernel's own cycle count, excluding allocation, array
initialisation and `printf`. For `gemm` that is 109,316 cycles inside a 208,020-cycle
program: tracking the whole-program figure, as `lvx-mibench` must, would halve
every real improvement before it showed.

**The oracle is generated, not archived.** PolyBench ships no reference output,
but it ships `POLYBENCH_DUMP_ARRAYS` and kernels that read no input — so the
reference is produced by running the same source natively on x86, for any
dataset size or data type, reproducibly. Every tracked run is diffed against it,
because on this target a miscompile has already looked like a speed-up: a stale
`libgcc` object carrying eight out-of-date instruction encodings made a `gemm`
prototype return wrong results while exiting 0.

## Both FP widths are the measurement

`TYPE` defaults to `float double` and a sweep produces both. An LVX SIMD lane
group is 128 bits wide whatever it holds — four floats or two doubles — and
scalar f32 and f64 cost the same. So the per-kernel float/double ratio is a
direct read-out of how much the vectorizer achieved: **~2× means the lanes are
filling, ~1× means the kernel is effectively scalar.**

## The first result

`results/lvx-{1,2}-O2-mini-{float,double}.tsv`, 2026-10-09, `-O2`, `MINI`,
atomic CPU. All four sweeps: 22 kernels `ok`, 7 `fp-N`, 1 `fp-contract`, **no
mismatches** — so every number below is a believable one.

```
30 kernels compared, mean float/double speedup 1.01x
>=1.6x (lanes filling): 0    <=1.15x (effectively scalar): 29
```

**Nothing in PolyBench is vectorized to any useful degree.** The best kernel is
`durbin` at 1.22×; two are *slower* in float than double (`jacobi-1d` 0.82×,
`trisolv` 0.99×); the rest sit at 1.00–1.09×. Comparing the two cores says the
same thing from the other side: on double, **not one kernel moves more than 2%**
between lvx-1 and lvx-2, and on float only `durbin` (−11.1%) and `gemm` (−1.4%)
do.

### But it is not that the vectorizer never runs

That is the finding the `simd_insns`/`scalar_fma` columns exist to make, and it
is the opposite of what the cycle counts alone suggest:

| | lvx-2, float, MINI |
|---|---|
| kernels emitting lane-wise SIMD | **23 of 30** |
| of those, kernels where the scalar FMA count is **unchanged** | **21 of 23** |
| of those, kernels gaining more than 2% | **1** (`durbin`) |

The vectorizer fires on most of the suite and grows the kernel by 30–60%
(`3mm` 289 → 470 instructions, `gemm` 195 → 298) — and the scalar
multiply-accumulate it was supposed to replace is **still there**. The vector
code is *additional*: it takes the easy elementwise loop and leaves the
reduction nest that is the actual kernel alone. `gemm` is the clearest case —
of its two loops only `C[i][j] *= beta` vectorizes, while the
multiply-accumulate stays scalar `ffmaw`/`fmulw`.

So the gap is not "turn the vectorizer on". It is reduction and
multiply-accumulate loop nests specifically, which is where
`lvx-gcc-while-ult-plan` is already aimed — now measured across 30 kernels
instead of one, with a per-kernel baseline to track against.

The seven kernels that emit no SIMD at all (`fdtd-2d`, `floyd-warshall`,
`gesummv`, `gramschmidt`, `heat-3d`, `jacobi-1d`, `jacobi-2d`) are a separate,
more basic list — identical code on both cores.

See `harness/README.md` for what bounds these numbers: `MINI` trip counts are
small, and the atomic CPU charges one cycle per bundle rather than modelling
memory. Neither affects the instruction-count evidence above.
