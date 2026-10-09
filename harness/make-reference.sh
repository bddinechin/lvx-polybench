#!/usr/bin/env bash
# Generate the correctness oracle for PolyBench on LVX, by running each kernel
# natively on x86-64 and keeping its array dump.
#
#   ./harness/make-reference.sh                  # MINI, double
#   DATASET=SMALL TYPE=float ./harness/make-reference.sh
#
# Writes reference-output/<dataset>-<type>/<kernel>.txt and a CHECKSUMS.txt
# beside them.  Commit the result: it is what every LVX run is diffed against,
# and regenerating it on a different host could move it under you.
#
# WHY A GENERATED ORACLE, AND NOT A SHIPPED ONE.  PolyBench ships no reference
# output -- unlike MiBench, where upstream's own `output_small.txt' is the
# reference.  What it ships instead is better: POLYBENCH_DUMP_ARRAYS, which
# prints every result array in a fixed format, and kernels that take no input
# at all (each init_array fills from its own index arithmetic).  So the oracle
# is reproducible rather than archival -- any host with a C compiler regenerates
# it, and it can be regenerated for a dataset size or a data type that upstream
# never published.
#
# WHY -ffp-contract=off ON THE ORACLE.  Plain x86-64 has no FMA (it needs -mfma
# or a -march that implies it), so a native build evaluates a*b+c in two
# separately rounded steps.  LVX has ffma and GCC contracts into it by default,
# so the two targets would disagree in the last bits on every kernel with a
# multiply-accumulate -- which is most of them.  Turning contraction off here
# makes the oracle the per-operation IEEE-754 result, the one thing both targets
# can agree on exactly.  The LVX side is NOT built this way: it keeps its
# default contraction, because that is the code whose performance is tracked.
# The residual disagreement is therefore real FMA rounding, which run.sh counts
# and reports as fp-N rather than failing -- see harness/README.md.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

DATASET=${DATASET:-MINI}

# BOTH FP WIDTHS BY DEFAULT.  32-bit and 64-bit FP are not two settings of one
# benchmark here, they are the measurement: a 128-bit LVX lane holds four floats
# or two doubles, so the float/double ratio per kernel is how much the
# vectorizer actually got.  A run that reports only one width cannot show that,
# so TYPE is a LIST and defaults to both.  One TSV per type -- the type is in
# the filename and in every row -- and harness/fpcompare.sh puts the two side by
# side.  TYPE=float runs just the one.
TYPES=${TYPE:-"float double"}
if [ "$(set -- $TYPES; echo $#)" -gt 1 ]; then
    rc=0
    for t in $TYPES; do
        echo "=== $t ==="
        TYPE=$t "$0" "$@" || rc=$?
        echo
    done
    exit $rc
fi
TYPE=$TYPES
CC=${CC:-gcc}

case "$TYPE" in
    float)  tmacro=DATA_TYPE_IS_FLOAT  ;;
    double) tmacro=DATA_TYPE_IS_DOUBLE ;;
    int)    tmacro=DATA_TYPE_IS_INT    ;;
    *) echo "TYPE must be float, double or int (got $TYPE)" >&2; exit 2 ;;
esac

outdir="$repo/reference-output/$(echo "$DATASET" | tr A-Z a-z)-$TYPE"
mkdir -p "$outdir"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

n=0; bad=0
while read -r path; do
    case "$path" in ''|\#*) continue ;; esac
    path=${path#./}
    dir=$(dirname "$path"); name=$(basename "$path" .c)

    # Native, dumping, contraction off.  POLYBENCH_DUMP_TARGET is stderr on
    # every target but LVX, so the dump is captured from fd 2 here.
    if ! $CC -O2 -ffp-contract=off -I "$repo/utilities" -I "$repo/$dir" \
         "$repo/utilities/polybench.c" "$repo/$path" \
         -D"${DATASET}_DATASET" -D"$tmacro" -DPOLYBENCH_DUMP_ARRAYS \
         -o "$work/$name" -lm > "$work/$name.buildlog" 2>&1; then
        printf '  %-16s BUILDFAIL\n' "$name"; bad=$((bad+1)); continue
    fi
    "$work/$name" > /dev/null 2> "$outdir/$name.txt"
    printf '  %-16s %8d bytes\n' "$name" "$(stat -c%s "$outdir/$name.txt")"
    n=$((n+1))
done < "$repo/utilities/benchmark_list"

( cd "$outdir" && sha256sum ./*.txt > CHECKSUMS.txt )
echo
echo "wrote $n references to $outdir  (buildfail: $bad)"
