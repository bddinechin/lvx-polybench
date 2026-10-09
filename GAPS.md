# Running PolyBench on LVX: the gaps, measured

Status 2026-10-09. Everything below was measured against the installed
toolchain and `gem5-lvx2.opt`, not inferred from reading code.

## Summary

PolyBench ports to LVX far more easily than MiBench did, and the reason is
structural rather than lucky: **the kernels take no input and make no system
calls.** Each one allocates its arrays, fills them from index arithmetic in
`init_array`, computes, and prints. There is no `argv` to deliver, no file to
open, no data to stage, and the only library surface is `malloc`, `printf` and
some of `libm`. All 30 kernels build and run on both cores at `-O2`, at both
32-bit and 64-bit FP.

Five gaps had to be closed, all of them in `utilities/polybench.{c,h}` — the
instrumentation, never a kernel. None is an ISA gap and none needed a change to
newlib, gem5 or the compiler.

| # | gap | fix | symptom if unfixed |
|---|---|---|---|
| 1 | `RDTSC` does not exist | read `$frcc` | assembler error |
| 2 | no `posix_memalign` in newlib | `memalign` | link error |
| 3 | `polybench_flush_cache` allocates 33 MB | off by default | `fatal: readBlob(0, ...)` |
| 4 | `%Ld` is a glibc extension | `%llu` | the measurement line is **empty** |
| 5 | `POLYBENCH_CYCLE_ACCURATE_TIMER` alone prints nothing | it now implies the timer | **no output, no error** |
| 6 | the dump goes to `stderr`, which gem5 shares | `stdout` on LVX | corrupted dump, unfilterable |
| 7 | `jacobi-1d` computes its FP32 kernel in FP64 | `SCALAR_VAL` | a **21.7% phantom FP32 slowdown** |
| 8 | `TYPE=int` builds 0 of 30 kernels | harness rejects it | 30 `buildfail` rows |
| 9 | **aliasing blocks vectorization in 20 of 30 kernels** | `-DPOLYBENCH_USE_RESTRICT` | **2.15× left on the table** |

Gaps 4, 5 and 6 are the dangerous ones. None produces an error message, and
each looks like a broken port or a broken benchmark rather than a missing
`#define`.

## 1. `RDTSC` does not exist — the cycle counter is `$frcc`

`polybench.c`'s `rdtsc()` is literally x86: `__asm__ volatile ("RDTSC" : "=a"
(cycles_lo), "=d" (cycles_hi))`, reassembling a 64-bit count from the EDX:EAX
pair RDTSC returns.

LVX has the same facility and it is simpler: **`$frcc`**, SRS 63, a 64-bit
free-running cycle counter read with the scalar `get`. One register, so there is
no hi/lo reassembly:

```c
__asm__ __volatile__ ("get %0 = $frcc\n\t;;" : "=r" (ret) : : "memory");
```

The `;;` terminates the VLIW bundle; the `"memory"` clobber keeps the read from
being scheduled across the kernel it is timing. This is the same register
`lvx-newlib` reads in `__lvx_cycles()` (`libgloss/lvx-mbr/counters.c`), from
which `clock()`, `times()` and `gettimeofday()` are all derived — so a cycle
count and a reported time cannot disagree here, and `_LVX_CPU_FREQ` (1 GHz) only
affects the derived *time*, never this count.

`PAPI` is not the answer, despite `polybench.h` offering `POLYBENCH_PAPI`: that
path collects hardware counters and **defines no timing function at all**
(`polybench_papi_print` prints counter values, and `polybench_print_instruments`
is redefined to it, replacing the timer). So porting PAPI would not have
produced a cycle count. `POLYBENCH_CYCLE_ACCURATE_TIMER` is the right hook.

## 2. newlib has `memalign`, not `posix_memalign`

`xmalloc` calls `posix_memalign (&ret, 4096, padded_sz)` unconditionally. newlib
ships `memalign` and `aligned_alloc` but not `posix_memalign`, so the link fails.
`memalign (4096, padded_sz)` has the same contract for the only alignment
PolyBench asks for — 4096 is a power of two and a multiple of `sizeof (void *)`
— so the fix is two lines and needs no newlib change. (A standalone
`posix_memalign` shim was the first attempt; folding it into `xmalloc` is better,
because a shim is a file every compile line has to remember.)

## 3. The cache flush allocates 33 MB and does not check — `readBlob(0, ...)`

This one is worth reading carefully, because the diagnostic names nothing.

```
src/mem/port_proxy.hh:185: fatal: readBlob(0, ...) failed
```

`polybench_flush_cache()` does:

```c
int cs = POLYBENCH_CACHE_SIZE_KB * 1024 / sizeof(double);   /* 32770 KB */
double* flush = (double*) calloc (cs, sizeof(double));      /* ~33 MB */
for (i = 0; i < cs; i++) tmp += flush[i];                   /* no NULL check */
```

The allocation fails on the ISS heap, the result is never checked, and the walk
dereferences NULL. Three things make it hard to find:

- it is reached through `polybench_prepare_instruments()`, so it fires **only
  once timing is enabled** — the kernel itself is fine, which points suspicion
  at the timer patch;
- the message names neither the allocation nor the benchmark;
- `POLYBENCH_CACHE_SIZE_KB` is an *LLC* size and looks like a tuning knob, not a
  thing that gets allocated.

There is also nothing to flush: the default atomic CPU models no cache at all,
and the pipeline model's L1s are 32 KB, so walking 33 MB would measure nothing
either way. So `POLYBENCH_NO_FLUSH_CACHE` is now the default under `__lvx__`,
with `POLYBENCH_FLUSH_CACHE` to force it back on.

## 4. `%Ld` is a glibc extension — the measurement comes out empty

`polybench_timer_print` prints the cycle delta with:

```c
printf ("%Ld\n", polybench_c_end - polybench_c_start);
```

`%Ld` is a glibc extension. newlib's `printf` does not parse it and drops the
conversion, so the program prints an empty line and exits 0. The run looks
complete and the measurement is simply gone. `%llu` with an explicit cast.

## 5. `POLYBENCH_CYCLE_ACCURATE_TIMER` on its own prints nothing

The trap in upstream's macro layering. `polybench.h` only defines the timer
macros under:

```c
# if defined(POLYBENCH_TIME) || defined(POLYBENCH_GFLOPS)
```

`POLYBENCH_CYCLE_ACCURATE_TIMER` is **not** in that list. On its own it merely
*selects* `rdtsc()` over `gettimeofday()` inside `polybench_timer_start/stop`,
while `polybench_print_instruments` stays defined as nothing. So the timer runs,
`$frcc` is read correctly twice, and the program prints no number at all —
which reads as a broken port rather than a missing `-DPOLYBENCH_TIME`.

Since defining it is only ever meant to choose the cycle counter, it now implies
the timer the way `POLYBENCH_TIME` does.

## 6. The dump must not go to `stderr`

`POLYBENCH_DUMP_TARGET` is `stderr` upstream, so that a timed run can be piped
without the dump polluting the measurement. On LVX stderr is the one stream that
cannot be trusted: the guest's fd 2 and gem5's own diagnostics land in it
together, and gem5 emits some of them **mid-run** (`Increasing stack size by one
page`). The dump prints an entire array as space-separated values with no
newline until the end, so an intrusion is not at a line boundary and **no
line-prefix filter can recover it**.

Measured: with the dump on stderr, 2 gem5 diagnostic lines sat inside it. On
stdout, which carries only gem5's banner and the guest's bytes, the dump comes
out clean and is cut free positionally (`harness/guest-output.py`, shared with
`lvx-mibench`).

The cost is that a dump and a timing print now share a stream. That was never a
combination to use: the dump's `printf` traffic dwarfs the kernel, so a dumped
run's cycle count measures `printf`. The harness builds and runs the two
separately.

## 7. `jacobi-1d` computed its FP32 kernel in FP64 — fixed

Not an LVX gap at all, but it corrupted an LVX measurement, so it belongs here.

`jacobi-1d.c` wrote its stencil coefficient as a bare literal:

```c
B[i] = 0.33333 * (A[i-1] + A[i] + A[i + 1]);          /* jacobi-1d */
B[i][j] = SCALAR_VAL(0.2) * (...);                    /* jacobi-2d, correct */
```

In C a bare `0.33333` is a **`double`**, so under `-DDATA_TYPE_IS_FLOAT` the
f32 sum was widened, multiplied in f64 and narrowed back — `3 fwidenwd`,
`2 fmuld`, `2 fnarrowdw` in the generated code. The kernel's FP32 number was
therefore not an FP32 measurement, and it cost **2,241 cycles of 12,552 —
21.7%** in conversions alone:

| | FP32 | FP64 | ratio |
|---|---|---|---|
| before | 12,552 | 10,312 | **0.82×** (FP32 *slower*) |
| after | 10,311 | 10,312 | **1.00×** |

`SCALAR_VAL(0.33333)` fixes it, and the printed result does not change — at
`%0.2f` the two roundings agree, which is exactly why no correctness check
caught it and why only the cycle count gave it away.

**It is the only kernel with this defect.** Checked all 30 for a bare FP
literal inside `#pragma scop`: `jacobi-1d` was the one. (`ludcmp` has one too,
in `init_array`, outside the timed region, so its figure was always valid;
`deriche`'s `-2.0` is already inside `SCALAR_VAL`.) 12 of 30 kernels contain a
bare literal *somewhere*, so the inconsistency is upstream-wide — it only
matters when it lands in the timed loop.

**The check that works, and two that do not.** Counting `fwiden` over the whole
assembly flags all 30, because `print_array`'s `fprintf` widens `float` to
`double` under C's default argument promotions. Scoping to the `kernel_*`
symbol flags none — the kernels are `static` and `-O2` inlines them into
`main`, so the symbol does not exist and the extraction silently yields
nothing. What discriminates is **`fnarrow*` or an f64 arithmetic op**:
`print_array` can only produce a widen, never either of those.

## 8. `TYPE=int` does not build, upstream

`polybench.h`'s per-kernel headers define `SCALAR_VAL` only under
`DATA_TYPE_IS_FLOAT` and `DATA_TYPE_IS_DOUBLE`. Every kernel that uses it
therefore fails to compile with `-DDATA_TYPE_IS_INT` — measured, **0 of 30
build**. The harness now rejects `TYPE=int` with that explanation rather than
emitting 30 `buildfail` rows.

## 9. Vectorization was blocked by aliasing, not by the vectorizer — 2.15x

The biggest effect measured on this target so far, and it overturns the first
conclusion drawn from this suite.

PolyBench's kernels take their arrays as plain pointer parameters, so GCC cannot
prove the output array does not overlap the inputs. The vectorizer says so
exactly:

```
gemm.c:94:27: missed: versioning for alias required: can't determine
              dependence between (*_37)[k_153] and (*_26)[j_152]
gemm.c:93:22: missed: would need a runtime alias check
gemm.c:93:22: missed: couldn't vectorize loop
gemm.c:90:19: optimized: loop vectorized using 32 byte vectors, unroll 8
```

Read the last two lines together: the trivial `C[i][j] *= beta` loop at line 90
vectorizes, and the multiply-accumulate at 93–94 that *is* the kernel does not.
At `-O2` GCC's default cost model is `very-cheap`, which refuses any loop
requiring a runtime alias check — so it declines to version and gives up.
**Measured: 20 of 30 kernels are blocked this way.**

### The fix is upstream's own flag

`polybench.h:69` already has the hook — `POLYBENCH_RESTRICT`, which
`-DPOLYBENCH_USE_RESTRICT` turns into `restrict` on every kernel array
parameter. No source edits.

| | gemm cycles | speedup | source edits | what it asserts |
|---|---|---|---|---|
| baseline `-O2` | 109,316 | 1.00× | — | — |
| `#pragma GCC ivdep` | 32,513 | 3.36× | **155** inner loops | this loop's dependences |
| `-fvect-cost-model=cheap` | 33,175 | 3.30× | none | policy, not facts |
| `-O3` | 59,008 | 1.85× | none | ditto, plus other passes |
| **`-DPOLYBENCH_USE_RESTRICT`** | **25,315** | **4.32×** | **none** | the whole function's aliasing |

All four work. `restrict` wins because it gives the *alias oracle* a fact rather
than relaxing a cost threshold, so it also improves addressing and scheduling,
not only the one loop `ivdep` covers — and `ivdep` would need annotating 155
loops across the suite. `-O3` is counterproductive, and `restrict -O3`
(37,548) is **worse than `restrict -O2`**.

### Suite-wide, lvx-2, `-O2`, MINI, float

```
30 kernels: mean 2.15x, best 2mm at 5.28x
>=1.5x faster: 14     slower: 0     correctness regressions: 0
```

Six of the seven kernels that previously emitted **no SIMD at all** now
vectorize: `heat-3d` 0→47 lane-wise instructions (4.51×), `fdtd-2d` 0→39
(2.74×), `jacobi-2d` 0→35 (2.95×), `jacobi-1d` 0→20 (3.15×), `gesummv` 0→18
(1.89×), `gramschmidt` 0→9 (1.36×). Only `floyd-warshall` still emits none.

### And the gain really is SIMD

The control settles it. `restrict` on **lvx-1**, which has no lane-wise
arithmetic at all, gives only **1.17×** — that part is better scalar addressing.
On lvx-2 it gives 2.15×. Comparing the two cores *with* restrict:

| | mean lvx-2 / lvx-1 |
|---|---|
| without `restrict` | **1.00×** — lvx-2 bought nothing |
| with `restrict` | **1.84×**, 13 kernels ≥1.3×, up to 4.81× (`heat-3d`) |

So the vectorizer and the lvx-2 back end were working the whole time; aliasing
was starving them. The earlier reading of this suite — "the vectorizer fires and
gains nothing because the scalar FMA stays" — described the symptom. The scalar
FMA stayed because the loop containing it was never vectorized.

FP32 vs FP64 moves with it, from a mean of 1.01× to **1.14×**, with two kernels
finally past 1.6× (`heat-3d` 3.25×, `2mm` 1.73×). Still short of the 2× that four
f32 lanes against two f64 lanes should give, so there is a second-order question
left — vector-width selection rather than whether vectorization happens.

### Still at 1.00x with restrict, and this is the real remaining list

`trmm`, `cholesky`, `durbin`, `lu`, `ludcmp`, `trisolv`, `seidel-2d`,
`floyd-warshall`, `nussinov` — triangular solvers and dependence-carrying
stencils, where the inner loop has a genuine loop-carried dependence or a
triangular bound. Those are a real vectorizer/ISA question, unlike the 21 that
only needed an aliasing fact.

### How this is tracked

`RESTRICT=1 ./harness/run.sh` writes a separate `*-restrict.tsv` series, and
`harness/restrictcompare.sh` diffs the two. Kept as two series rather than one
flag because they measure different things: with it the compiler is *told* the
arrays do not alias, without it it must prove it and cannot.

`restrict` is sound here, and checked rather than assumed: every array is its own
`polybench_alloc_data` → `xmalloc` → `memalign` allocation, and no kernel
receives the same `POLYBENCH_ARRAY` twice (verified across all 30 call sites).
The correctness gate runs on the restrict series too — all 30 kernels keep their
verdict class, no MISMATCH.

## What is *not* a gap

**The ISA.** All 30 kernels assemble and link on both cores at both FP widths.
Nothing in the suite asked for an instruction the assembler could not provide.

**`gettimeofday`.** It exists — in `libgloss.a` and `libnosys.a`, not in
`libc.a`, derived from `$frcc` — so upstream's default `POLYBENCH_TIME` path
works too and reports exact *simulated* time. It is not what the harness tracks,
because a cycle count needs no clock-frequency assumption, but it is not missing.
(An earlier note in this project said it was absent; that came from an `nm` of
`libc.a` alone.)

**Dataset sizes.** `MINI` is the tracked size and runs in ~10^5 kernel cycles.
`SMALL` and above are available and correct, just slower; see `harness/README.md`
for why `MINI` is the right default for per-commit tracking.

## Open, and worth doing

- **A staleness check.** The gemm miscompile that motivated this port was a
  stale `libgcc` object — `divv.o` from an older binutils, carrying eight
  instructions whose encodings had since changed — and nothing in the build
  reported it. Both this harness and `validation/` would benefit from a `stat`
  comparison of the installed toolchain against the ISS binary.
- **The pipeline model.** Every number here is from the default atomic CPU,
  which charges one cycle per bundle and models no memory latency. That makes it
  a clean measure of *bundle count* — which is what scheduling and bundling
  changes move — but it is not a cycle count a real machine would produce.
  `LVX_CPU=minor` runs the pipeline model with L1 caches and is the honest
  measurement; it has not been run across the suite yet because it is much
  slower.
