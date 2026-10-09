#!/usr/bin/env bash
# What -DPOLYBENCH_USE_RESTRICT buys, per kernel.
#
#   ./harness/restrictcompare.sh                  # lvx-2, -O2, MINI, float
#   ARCH=lvx-1 TYPE=double ./harness/restrictcompare.sh
#
# WHY THIS IS THE FIRST THING TO LOOK AT.  PolyBench's kernels take their arrays
# as plain pointer parameters, so GCC cannot prove the output array does not
# overlap the inputs.  At -O2 the default cost model is `very-cheap', which
# refuses any loop needing a runtime alias check -- so the vectorizer reports
# "would need a runtime alias check" and gives up on the loop that matters,
# while still vectorizing the trivial elementwise one beside it.  Measured: 20
# of 30 kernels are blocked this way.
#
# POLYBENCH_USE_RESTRICT is upstream's own hook (polybench.h:69) for exactly
# this: it makes POLYBENCH_nD emit `restrict' on every kernel array parameter.
# It is sound here because every array is a separate
# polybench_alloc_data -> xmalloc -> memalign allocation, so no two parameters
# can overlap -- and the correctness gate still runs, so a kernel where it were
# unsound would read MISMATCH rather than quietly scoring a win.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(dirname "$here")"
ARCH=${ARCH:-lvx-2}; OPT=${OPT:-2}; DATASET=${DATASET:-MINI}; TYPE=${TYPE:-float}
ds=$(echo "$DATASET" | tr A-Z a-z)
base=$repo/results/$ARCH-O$OPT-$ds-$TYPE.tsv
rest=$repo/results/$ARCH-O$OPT-$ds-$TYPE-restrict.tsv
for f in "$base" "$rest"; do
    [ -f "$f" ] || { echo "missing $f -- run ./harness/run.sh and RESTRICT=1 ./harness/run.sh" >&2; exit 2; }
done
echo "base: $(basename "$base")   restrict: $(basename "$rest")"
echo
awk -v bf="$base" -v rf="$rest" '
BEGIN {
    FS = "\t"
    while ((getline l < bf) > 0) { split(l,a,FS); if (a[1]=="kernel") continue
        bc[a[1]]=a[7]; bs[a[1]]=a[14]; bf_[a[1]]=a[15]; bk[a[1]]=a[13] }
    n=0
    while ((getline l < rf) > 0) { split(l,a,FS); if (a[1]=="kernel") continue
        ord[++n]=a[1]; rc[a[1]]=a[7]; rs[a[1]]=a[14]; rf_[a[1]]=a[15]
        rk[a[1]]=a[13]; rv[a[1]]=a[6] }
    printf("%-16s %11s %11s %8s %9s %9s %s\n",
           "KERNEL","BASE_CYC","RESTR_CYC","SPEEDUP","SIMD","SFMA","CORRECT")
    for (i=1;i<=n;i++) { b=ord[i]
        if (!(b in bc) || bc[b]=="" || rc[b]=="") continue
        sp = (rc[b]+0==0) ? 0 : bc[b]/rc[b]
        printf("%-16s %11s %11s %7.2fx %4s->%-4s %4s->%-4s %s\n",
               b, bc[b], rc[b], sp, bs[b], rs[b], bf_[b], rf_[b], rv[b])
        tot++; sum+=sp; if (sp>=1.5) win++; if (sp<0.98) lose++
        if (sp>best) { best=sp; bestk=b }
    }
    if (tot) {
        printf("\n  %d kernels: geomean-ish mean %.2fx, best %s at %.2fx\n", tot, sum/tot, bestk, best)
        printf("  >=1.5x faster: %d     slower: %d\n", win, lose)
    }
}' /dev/null
