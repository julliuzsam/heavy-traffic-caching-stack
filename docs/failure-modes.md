# Failure modes and resilience

A cache that only works on the happy path is a liability: it moves the failure
from "slow" to "down". This is how the stack behaves when things go wrong, and
the design choices that keep a bad day from becoming an outage.

## 1. The thundering herd (cache stampede)

**Failure:** a popular page's cache entry expires. Before the first request can
re-render and re-store it, hundreds of concurrent requests all see a MISS and
all hit PHP at once. PHP saturates, render times climb, more entries expire
while workers are blocked, and the site spirals.

**Mitigations in this stack:**

- **TTL jitter** (`set_random $exp 13800 15000` in `wordpress.conf`). Entries
  created together, for example the flood during a traffic spike, get TTLs
  spread across a ~20-minute window instead of expiring in the same second. This
  alone removes the *synchronised* stampede, which is the common case.
- **A bounded PHP pool** (`pm.max_children = 30`). A stampede on a single hot
  key is capped at the worker count: at most 30 concurrent renders, then excess
  requests queue briefly or shed (fast 503) rather than fork-bombing the box.
- **Object cache on the miss path.** Even the renders that do hit PHP during a
  stampede share Redis-cached query results, so they are far cheaper than a
  cold render.

**The honest limit:** nginx + srcache has no built-in per-key render lock (what
`proxy_cache_lock` gives the proxy path). For a workload where a single key is
hot enough that 30 simultaneous renders still hurt, the next step is a
request-coalescing lock: a short `SET key ... NX PX` in Redis taken by the first
renderer, with the rest serving the slightly-stale previous copy. That is a
deliberate add-on, not on by default, because it trades a little staleness for
herd protection and most sites don't need it. Knowing *when* you cross that line
is the point.

## 2. Redis unavailable or slow

**Failure:** the cache tier, which sits on the fast path of *every* request,
becomes unreachable or starts timing out.

**Behaviour:** the stack **fails open.** `srcache` treats a failed fetch as a
MISS and renders live; the short connect/read timeouts on the `redis_cache`
upstream (`upstream.conf`) mean a sick Redis fails over to PHP in milliseconds
rather than hanging the request. The site gets slower (every request is now a
render) but stays *up*. A slow cache must never be slower than no cache.

**Capacity caveat:** with the cache gone, PHP sees ~30x its normal load. The box
will not serve peak traffic uncached. That is expected and acceptable for a
short Redis blip, and it is exactly why Redis runs with `save ""` / `appendonly
no`: a cache restart is cheap and warms back up in seconds from live renders.

## 3. PHP-FPM saturation

**Failure:** the miss path gets more work than 30 workers can clear (a Redis
outage, a crawler hammering uncacheable URLs, a slow dependency).

**Behaviour:** the pool is a **deliberate ceiling, not a soft target.** When all
workers are busy, nginx returns a fast 503 and, via `error_page`, the static
`_offline.html`, instead of letting the queue grow until the box swaps and dies.
Load shedding is a feature: a small number of users get a retry page; everyone
else, served from cache, never notices. Recovery is automatic once the spike
passes; no manual restart, no swap-death.

## 4. Invalidation races and stale content

**Failure:** content is edited but the cached page doesn't update, or a purge is
missed and a page is stale "forever".

**Behaviour:** two independent clocks bound the worst case:

- **Event purge** deletes the `fullpage:*` key on publish/update, so edits
  appear immediately on the happy path.
- **TTL** (4h give or take the jitter) is the backstop, so even if a purge is
  dropped (deploy bug, queue hiccup), no page is stale for longer than the TTL.
  Neither mechanism alone is safe; together the failure of either is bounded.

A subtle race, where a request re-populates a key *between* the edit and the
purge, is also bounded by the TTL, and is why the purge targets the exact key
rather than relying on TTL alone.

## 5. Cold cache after deploy/restart

**Failure:** a deploy or Redis restart empties the cache; the first wave of
traffic is 100% misses.

**Behaviour:** acceptable by design for this traffic shape, but for a large site
the warm-up itself can stampede (see section 1). Mitigation when it matters: a
small post-deploy warmer that requests the top-N URLs (from access logs or the
sitemap) to repopulate the hottest keys before traffic arrives, and rolling
rather than all-at-once cache flushes.

---

### The through-line

Every failure here degrades to **slower**, never to **down**, and every
degradation is **bounded**: by a timeout, a worker ceiling, or a TTL. That is
the difference between "I turned on caching" and operating a cache at scale.
