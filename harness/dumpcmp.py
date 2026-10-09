#!/usr/bin/env python3
"""Compare a PolyBench array dump against the native x86 reference.

    dumpcmp.py <reference> <got>

Prints one verdict word on stdout and exits 0 if it is acceptable, 1 if not:

    ok          byte-identical
    fp-N        N values differ, every one of them by at most one unit in the
                last printed place
    MISMATCH:.. anything else, with the reason

WHY A TOLERANT COMPARE IS CORRECT HERE, AND WHY IT IS STILL A GATE.

The reference is built -ffp-contract=off (see make-reference.sh) while the LVX
side keeps the contraction that makes ffma fire, so the two differ by genuine
FMA rounding on every multiply-accumulate kernel.  Refusing that would mean
either tracking the performance of code that is not allowed to use the
machine's fused multiply-add, or having no correctness gate at all.

What keeps this from degenerating into "close enough" is that PolyBench prints
through DATA_PRINTF_MODIFIER, which is "%0.2f"/"%0.2lf" -- two decimals.  A
1-ulp difference in a double is invisible at that precision unless the value
sits exactly on a rounding boundary, so FMA contraction shows up as a handful
of values moved by exactly 0.01 and nothing else.  A miscompile does not look
like that: it moves values by orders of magnitude, produces nan or inf, or
changes how many values there are.  So the bound is one unit in the last place
PRINTED, not a relative epsilon -- it is derived from the format rather than
guessed, and a lane-permutation or stale-object bug cannot hide under it.
"""
import math
import re
import sys

NUM = re.compile(r'^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$')


def decimals(tokens):
    """One unit in the last printed place, read off the data itself."""
    d = 0
    for t in tokens:
        if '.' in t and 'e' not in t.lower():
            d = max(d, len(t.split('.', 1)[1]))
    return 10.0 ** -d if d else 1.0


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    try:
        with open(sys.argv[1], 'rb') as f:
            ref = f.read()
        with open(sys.argv[2], 'rb') as f:
            got = f.read()
    except OSError as e:
        print('MISMATCH: %s' % e)
        return 1

    if ref == got:
        print('ok')
        return 0

    rt = ref.split()
    gt = got.split()
    if len(rt) != len(gt):
        print('MISMATCH: %d values in the reference, %d in the output'
              % (len(rt), len(gt)))
        return 1

    # The dump interleaves words ("begin dump: C") with numbers; compare the
    # words exactly, since a difference there is a structural one.
    rs = [t.decode('utf-8', 'replace') for t in rt]
    gs = [t.decode('utf-8', 'replace') for t in gt]
    ulp = decimals([t for t in rs if NUM.match(t)])

    ndiff = 0
    worst = 0.0
    worst_at = None
    for i, (a, b) in enumerate(zip(rs, gs)):
        if a == b:
            continue
        ndiff += 1
        if not (NUM.match(a) and NUM.match(b)):
            print('MISMATCH: value %d is %r, reference has %r' % (i, b, a))
            return 1
        fa, fb = float(a), float(b)
        if math.isnan(fb) or math.isinf(fb):
            print('MISMATCH: value %d is %s (reference %s)' % (i, b, a))
            return 1
        d = abs(fa - fb)
        if d > worst:
            worst, worst_at = d, (i, a, b)

    if worst > 1.5 * ulp:
        i, a, b = worst_at
        print('MISMATCH: %d of %d values differ, worst at %d: %s vs %s '
              '(delta %g, last printed place %g)'
              % (ndiff, len(rs), i, a, b, worst, ulp))
        return 1

    print('fp-%d' % ndiff)
    return 0


if __name__ == '__main__':
    sys.exit(main())
