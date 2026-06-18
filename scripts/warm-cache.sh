#!/usr/bin/env bash
# warm-cache.sh - repopulate the full-page cache after a deploy or Redis restart.
#
# A cold cache means the first wave of traffic is 100% misses, which on a large
# site can stampede PHP (see docs/failure-modes.md section 5). Run this immediately
# after a deploy/flush to pull the hottest URLs back into Redis *before* real
# traffic arrives, at a controlled concurrency that never saturates the pool.
#
# URL sources, in order of preference:
#   1. an explicit url list passed as $1 (one path per line)
#   2. the sitemap (good enough proxy for "pages worth caching")
#
# Usage:
#   scripts/warm-cache.sh urls.txt
#   BASE_URL=https://example.com CONCURRENCY=4 scripts/warm-cache.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
CONCURRENCY="${CONCURRENCY:-4}"     # stay well under pm.max_children
LIST="${1:-}"

fetch() {
  # warm only - discard the body, but trigger a MISS->store. Report cache status.
  local url="$1"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code} %header{x-cache-status}' "$url" || echo "ERR")
  printf '%-6s %s\n' "$status" "$url"
}
export -f fetch
export BASE_URL

urls() {
  if [[ -n "$LIST" && -f "$LIST" ]]; then
    sed "s#^#${BASE_URL}#" "$LIST"
  else
    # crude sitemap scrape; replace with your real sitemap location
    curl -s "${BASE_URL}/sitemap.xml" \
      | grep -oE '<loc>[^<]+' | sed 's/<loc>//' \
      || { echo "no url list and no sitemap at ${BASE_URL}/sitemap.xml" >&2; exit 1; }
  fi
}

echo "Warming cache via ${BASE_URL} at concurrency ${CONCURRENCY}..."
urls | xargs -P "${CONCURRENCY}" -I{} bash -c 'fetch "$@"' _ {}
echo "Done. Re-run scripts/cache-hitratio.sh to confirm the ratio recovered."
