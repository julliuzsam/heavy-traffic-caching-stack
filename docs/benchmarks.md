# Benchmarks and methodology

> **Honesty note.** The headline numbers below come from a **production system**
> (a content platform serving ~300k unique visitors/day on a 4-vCPU node). The
> `docker-compose` stack in this repo reproduces the same *architecture* so you
> can measure the *shape* of the result on your own hardware. The absolute
> numbers you get will depend on your machine. The point of the repo is the
> method, not a leaderboard score.

## Production reference numbers (measured live)

| Metric | Value | How it was measured |
| --- | --- | --- |
| Full-page cache hit ratio | **~97%** | `keyspace_hits / (hits + misses)` from `redis-cli INFO stats` |
| Cache ops/sec (sustained) | ~1,000 ops/s | `instantaneous_ops_per_sec` |
| Cached objects resident | ~1M keys in ~1 GB | `INFO keyspace` / `INFO memory`, capped at 1.5 GB `allkeys-lru` |
| App node | 4 vCPU, ~16 GB RAM | n/a |
| Load average (steady state) | well under 1.5 on 4 cores | `uptime` |

At a 97% hit ratio, only ~3 of every 100 dynamic-looking requests reach PHP.
That single fact is why a small node absorbs a large audience: the reverse proxy,
not the application, answers almost everything.

## Reproduce locally

```bash
make up                     # start nginx + PHP/WordPress + MariaDB + Redis
# complete the one-time WordPress install at http://localhost:8080
make bench                  # mixed anonymous + logged-in load test
make hitratio               # read the live Redis hit ratio
```

### What to look for

The mixed test (`load/k6-mixed.js`) asserts the architecture, not just speed:

- `cache_hit_rate > 0.90`: anonymous reads are served from Redis.
- `anon_latency p95 < 50ms`: the cached path is fast.
- `dynamic_latency p95 < 400ms`: the logged-in path is **live** and still healthy.
- `dynamic was NOT cached` check passes: proof the bypass logic actually works
  (a logged-in user never receives a cached, shared page).

## Before / after (same box, cache on vs off)

Representative shape from the reproducible stack on a 4-core laptop. Run it on
yours and fill in your own column; the *ratio* is the point.

| Scenario | Throughput | p95 latency | PHP workers busy |
| --- | --- | --- | --- |
| Cache **off** (every request hits PHP) | ~baseline | high, climbs under load | saturates, then 503s |
| Cache **on**, anonymous traffic | **10 to 30x baseline** | low, flat under load | near-idle |
| Cache **on**, mixed (90/10) | close to anonymous | low for reads, bounded for live | only the ~10% live slice |

The numbers that matter are not "how fast is one page" but "how does the system
behave when traffic multiplies". Cache-off degrades super-linearly; cache-on
stays flat until the *miss* path saturates, which is far, far later.
