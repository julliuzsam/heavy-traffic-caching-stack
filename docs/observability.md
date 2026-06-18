# Observability

You cannot operate a cache you cannot see. The whole architecture rests on a hit
ratio staying near 97%, so that number, and the health of the small miss path
behind it, is what gets measured and alerted on.

## The one signal that matters most: hit ratio

Hit ratio is the cache's **health check**, not just a vanity metric. A sudden
drop means something is wrong *before* the box falls over:

| Symptom | Likely cause |
| --- | --- |
| Hit ratio falls, traffic flat | A cookie/plugin started setting a cookie on every response (every request now matches `$skip_cache`), or a deploy changed URLs/query params and blew the key space up |
| Hit ratio fine, PHP busy climbs | Stampede on a hot key, or a crawler hammering uncacheable URLs |
| Hit ratio near zero after deploy | Cold cache (expected, transient) or Redis unreachable (fail-open, so check Redis) |

Two equivalent ways to read it:

```bash
# from Redis (cumulative since start)
redis-cli INFO stats | awk -F: '/keyspace_hits|keyspace_misses/{print}'

# from the nginx access log (live, windowed), see scripts/cache-hitratio.sh
tail -n 100000 /var/log/nginx/access.log | scripts/cache-hitratio.sh
```

The nginx log already carries the decision per request via the `cache` log
format (`$srcache_fetch_status` = HIT / MISS / BYPASS) defined in `nginx.conf`,
and every response carries `X-Cache-Status` for spot checks with `curl -I`.

## What to scrape (Prometheus / Grafana)

The stack exposes the standard surfaces, locked to localhost (see the private
`location` blocks in `wordpress.conf`):

| Source | Endpoint / exporter | Key series |
| --- | --- | --- |
| nginx | `/_nginx_status` (`stub_status`) + log exporter | requests/s, active conns, **hit ratio** |
| PHP-FPM | `/_fpm_status` -> `php-fpm_exporter` | **active vs idle workers**, listen queue, slow requests |
| Redis | `redis_exporter` | hit/miss, evictions, memory vs maxmemory, ops/s |
| MariaDB | `mysqld_exporter` | slow queries, InnoDB buffer-pool hit %, threads running |

## Alerts worth paging on (RED method on the miss path)

The cached path is effectively free; alert on the **miss path**, which is the
only thing that can actually saturate:

- **Hit ratio below 90%** for 5 min: the cache is degraded (key-space blow-up or
  a Redis problem). This is the leading indicator; it fires before latency does.
- **PHP-FPM active workers at or above 90% of `max_children`** for 2 min:
  approaching the load-shedding ceiling, and the miss path can't keep up.
- **PHP-FPM listen queue above 0** sustained: requests are queueing for a worker.
- **Redis evictions rising with memory at `maxmemory`**: the working set outgrew
  the cap and hit ratio will start sliding. Raise `maxmemory` or shorten TTL.
- **5xx rate above baseline**: separate real backend 500s from intentional 503
  load-shedding in the dashboard, because they mean very different things.

## Why this set

Most "WordPress is slow" dashboards watch page latency and CPU. Those are
*lagging* indicators: by the time they move, users already feel it. Hit ratio
and FPM worker saturation are *leading* indicators: they tell you the cache is
slipping or the miss path is filling up while there is still headroom to react.
That shift, from watching symptoms to watching the mechanism, is the difference
between firefighting and operating.
