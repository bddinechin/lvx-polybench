#!/usr/bin/env bash
# Put the 32-bit and 64-bit FP runs of one configuration side by side.
#
#   ./harness/fpcompare.sh                       # lvx-2, -O2, MINI
#   ARCH=lvx-1 OPT=3 DATASET=SMALL ./harness/fpcompare.sh
#   ./harness/fpcompare.sh results/a-float.tsv results/a-double.tsv
#
# WHAT THE RATIO MEANS.  An LVX SIMD lane group is 128 bits wide whatever it
# holds, so a float vector is four lanes and a double vector two.  A kernel the
# vectorizer handles well should therefore run its float version close to twice
# as fast as its double version; one it leaves scalar runs them at about the
# same speed, because scalar f32 and f64 cost the same on this machine.
#
# So `speedup' here is not a property of the ISA, it is a read-out of the
# compiler: ~2.0 means the kernel vectorized and the lanes are being filled,
# ~1.0 means it did not, and the kernels sitting at 1.0 are the work list.
# (Expect some below 1.0 as well -- a float kernel still pays for f32<->f64
# conversions around libm calls, and MINI is small enough for loop overhead to
# show.)  This is the same conclusion the 256-bit measurements reached from the
# other direction: see the lvx2-256bit-vectorization-data note.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(dirname "$here")"
ARCH=${ARCH:-lvx-2}; OPT=${OPT:-2}; DATASET=${DATASET:-MINI}
ds=$(echo "$DATASET" | tr A-Z a-z)
f=${1:-$repo/results/$ARCH-O$OPT-$ds-float.tsv}
d=${2:-$repo/results/$ARCH-O$OPT-$ds-double.tsv}
for t in "$f" "$d"; do
    [ -f "$t" ] || { echo "missing $t -- run ./harness/run.sh first" >&2; exit 2; }
done
echo "float: $(basename "$f")   double: $(basename "$d")"
echo
awk -v ff="$f" -v df="$d" '
BEGIN {
    FS = "\t"
    while ((getline l < ff) > 0) { split(l,a,FS); if (a[1]=="kernel") continue
        fc[a[1]]=a[6]; fk[a[1]]=a[7]; ft[a[1]]=a[10] }
    n = 0
    while ((getline l < df) > 0) { split(l,a,FS); if (a[1]=="kernel") continue
        ord[++n]=a[1]; dc[a[1]]=a[6]; dk[a[1]]=a[7]; dt[a[1]]=a[10] }
    printf("%-16s %14s %14s %8s  %-10s %-10s\n",
           "KERNEL","FLOAT_CYC","DOUBLE_CYC","SPEEDUP","F_CORRECT","D_CORRECT")
    for (i=1;i<=n;i++) { b=ord[i]
        if (!(b in fk)) continue
        s = (fk[b]=="" || dk[b]=="" || fk[b]+0==0) ? "" : sprintf("%.2fx", dk[b]/fk[b])
        printf("%-16s %14s %14s %8s  %-10s %-10s\n",
               b, (fk[b]==""?"?":fk[b]), (dk[b]==""?"?":dk[b]), (s==""?"-":s),
               fc[b], dc[b])
        if (s != "") { tot++; sum += dk[b]/fk[b]
                       if (dk[b]/fk[b] >= 1.6) vec++
                       else if (dk[b]/fk[b] <= 1.15) scal++ }
    }
    if (tot) {
        printf("\n  %d kernels compared, mean speedup %.2fx\n", tot, sum/tot)
        printf("  >=1.6x (lanes filling): %d    <=1.15x (effectively scalar): %d\n",
               vec, scal)
    }
}' /dev/null
