#!/usr/bin/env bash
# Compare two harness runs, per kernel.
#
#   ./harness/compare.sh results/lvx-2-O2-mini-double.tsv results/...-double.tsv
#
# Reports every metric that moved by more than THRESH (default 2%), and every
# change in the correctness column.  Per kernel, deliberately: an aggregate
# hides exactly what matters.  A vect.exp A/B during this project read as +8/-8
# -- apparently neutral -- while concealing a real regression and a separate set
# of gains; only the per-test diff found it.
#
# A correctness change is reported first and loudly, because a cycle count from
# a run whose output is wrong is not a performance result.  A kernel that "got
# 40% faster" and stopped matching its reference did not get faster.
#
# fp-N -> fp-M is NOT reported as a correctness change when both are fp-*: the
# count is how many printed values FMA contraction moved in the last place, and
# it legitimately shifts when the schedule changes which multiply-adds fuse.
# Movement into or out of ok/MISMATCH is always reported.
set -u
THRESH=${THRESH:-2}
[ $# -eq 2 ] || { sed -n '2,20p' "$0"; exit 2; }

awk -v thresh="$THRESH" -v oldf="$1" -v newf="$2" '
function pct(o, n) { return (o == 0 || o == "") ? 0 : (n - o) * 100.0 / o }
function cls(v) { return (v ~ /^fp-[0-9]+$/) ? "fp" : v }
BEGIN {
    FS = "\t"
    while ((getline line < oldf) > 0) {
        split(line, f, FS); if (f[1] == "kernel") continue
        oc[f[1]]=f[6]; okc[f[1]]=f[7]; opc[f[1]]=f[8]; obd[f[1]]=f[9]
        otx[f[1]]=f[10]; oin[f[1]]=f[11]; osb[f[1]]=f[12]
    }
    nb = 0
    while ((getline line < newf) > 0) {
        split(line, f, FS); if (f[1] == "kernel") continue
        order[++nb]=f[1]
        nc[f[1]]=f[6]; nkc[f[1]]=f[7]; npc[f[1]]=f[8]; nbd[f[1]]=f[9]
        ntx[f[1]]=f[10]; nin[f[1]]=f[11]; nsb[f[1]]=f[12]
    }

    hdr = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc)) { printf("  NEW       %-16s (not in the baseline)\n", b); continue }
        if (cls(oc[b]) != cls(nc[b])) {
            if (!hdr) { print "CORRECTNESS CHANGED:"; hdr = 1 }
            printf("  %-16s %s -> %s\n", b, oc[b], nc[b])
        }
    }
    for (b in oc) if (!(b in nc)) printf("  GONE      %-16s (in the baseline, not in this run)\n", b)
    if (hdr) print ""

    print "METRICS (only moves beyond " thresh "%):"
    any = 0
    for (i = 1; i <= nb; i++) {
        b = order[i]
        if (!(b in oc) || nkc[b] == "" || okc[b] == "") continue
        pk = pct(okc[b], nkc[b]); pp = pct(opc[b], npc[b])
        pt = pct(otx[b], ntx[b]);  pi = pct(oin[b], nin[b])
        if (pk > thresh || pk < -thresh || pp > thresh || pp < -thresh || \
            pt > thresh || pt < -thresh || pi > thresh || pi < -thresh) {
            any = 1
            printf("  %-16s kernel %+6.1f%%  prog %+6.1f%%  text %+6.1f%%  insns %+6.1f%%", \
                   b, pk, pp, pt, pi)
            if (nc[b] != "ok" && nc[b] !~ /^fp-/ && nc[b] != "") printf("   [correct=%s]", nc[b])
            printf("\n")
        }
    }
    if (!any) print "  (nothing moved beyond the threshold)"
}' /dev/null
