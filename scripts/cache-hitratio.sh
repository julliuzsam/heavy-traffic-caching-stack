#!/usr/bin/env bash
# cache-hitratio.sh - compute the live full-page cache hit ratio from the nginx
# access log, broken down by HIT / MISS / BYPASS.
#
# The `cache` log_format (see nginx/nginx.conf) puts $srcache_fetch_status in
# field 3, e.g.:
#   203.0.113.7 0.001 HIT [18/Jun/2026:21:07:08 +0200] "GET / HTTP/2" 200 18342
#
# Usage:
#   tail -n 100000 /var/log/nginx/access.log | scripts/cache-hitratio.sh
#   scripts/cache-hitratio.sh /var/log/nginx/access.log
#
# A healthy content site sits around 95-98% HIT. A sustained drop is the
# earliest signal that the cache is degraded - see docs/observability.md.
set -euo pipefail

src="${1:-/dev/stdin}"

awk '
  { s = $3; total++; n[s]++ }
  END {
    if (total == 0) { print "no log lines on input"; exit 1 }
    hit    = n["HIT"]    + 0
    miss   = n["MISS"]   + 0
    bypass = n["BYPASS"] + 0
    cacheable = hit + miss
    printf "requests   : %d\n", total
    printf "HIT        : %d\n", hit
    printf "MISS       : %d\n", miss
    printf "BYPASS     : %d  (intentionally dynamic: logged-in / cart / admin)\n", bypass
    if (cacheable > 0)
      printf "hit ratio  : %.2f%%  (of cacheable traffic)\n", 100*hit/cacheable
    printf "served live: %.2f%%  (MISS+BYPASS of all traffic -> reached PHP)\n",
           100*(miss+bypass)/total
  }
' "$src"
