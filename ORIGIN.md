# Provenance

Pristine import of **PolyBench/C 4.2.1-beta**, the polyhedral benchmark suite
of Louis-Noël Pouchet, now maintained by Tomofumi Yuki.

Downloaded **2026-10-09** from <https://sourceforge.net/projects/polybench/>
as `polybench-c-4.2.1-beta.tar.gz`, unpacked exactly as shipped and committed
unmodified in the first commit of this repository (`ec89404`). SHA-256 of what
was downloaded is in `ORIGIN-checksums.txt`, so the import can be re-verified
against the upstream file.

30 kernels in four groups, per upstream's own `utilities/benchmark_list`:

| group | kernels |
|---|---|
| `datamining` | correlation, covariance |
| `linear-algebra/blas` | gemm, gemver, gesummv, symm, syr2k, syrk, trmm |
| `linear-algebra/kernels` | 2mm, 3mm, atax, bicg, doitgen, mvt |
| `linear-algebra/solvers` | cholesky, durbin, gramschmidt, lu, ludcmp, trisolv |
| `medley` | deriche, floyd-warshall, nussinov |
| `stencils` | adi, fdtd-2d, heat-3d, jacobi-1d, jacobi-2d, seidel-2d |

`medley/nussinov/Nussinov.orig.c` is shipped alongside `nussinov.c` as the
original un-optimised version and is not in `benchmark_list`, so the harness
does not build it.

## Licensing

PolyBench/C is distributed under the GNU GPL v2 or later; `LICENSE.txt` is
upstream's own and is imported untouched. Nothing here relicenses it. This
repository adds only harness and documentation files of its own.

## Why the first commit is unmodified

Everything LVX needs — a cycle counter that exists on this machine, an
allocator newlib actually ships, a dump stream that survives the ISS — is a
*change* to this code. Keeping the import pristine makes each one a reviewable
diff against upstream rather than part of an opaque drop, which is the same
reason `lvx-binutils` and `lvx-gcc` are forks with upstream as their base, and
the same choice `lvx-mibench` made.

`git log --follow utilities/polybench.c` is therefore the complete list of what
porting PolyBench to LVX required.

## Size

800 KB, 80 files. There is no input data: every kernel fills its own arrays
from index arithmetic in `init_array`, which is what makes the suite so much
better suited to an ISS than MiBench — nothing to stage, nothing to copy, and a
reference output that can be *generated* rather than archived. See
`harness/README.md`.
