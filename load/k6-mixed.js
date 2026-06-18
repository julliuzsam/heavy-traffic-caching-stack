// k6-mixed.js - a realistic mixed workload.
//
// The whole thesis of this repo is that you cannot judge a cache by hammering
// one URL. Real traffic is a blend: a large majority of anonymous readers who
// SHOULD hit cache, plus a minority of logged-in / cart / comment requests
// that MUST bypass it. This test reproduces that blend and asserts that:
//   1. anonymous reads are served from cache (X-Cache-Status: HIT)
//   2. logged-in reads are NOT cached (BYPASS) and still succeed
//   3. p95 latency stays low even though PHP only ever sees the bypass slice
//
// Run:  k6 run load/k6-mixed.js
//       BASE_URL=http://localhost:8080 k6 run load/k6-mixed.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';

const cacheHitRate   = new Rate('cache_hit_rate');         // share of anon reads served from cache
const anonLatency    = new Trend('anon_latency', true);
const dynamicLatency = new Trend('dynamic_latency', true);

export const options = {
  scenarios: {
    // ~90% of users: anonymous readers browsing content -> should be cache HITs
    anonymous_readers: {
      executor: 'ramping-vus',
      exec: 'anonymous',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 180 },
        { duration: '2m',  target: 180 },
        { duration: '30s', target: 0 },
      ],
    },
    // ~10% of users: logged-in / cart activity -> must BYPASS cache, hit PHP live
    logged_in_users: {
      executor: 'ramping-vus',
      exec: 'loggedIn',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 20 },
        { duration: '2m',  target: 20 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    // anonymous reads should be overwhelmingly cache hits once warm
    cache_hit_rate:           ['rate>0.90'],
    'anon_latency':           ['p(95)<50'],    // served from Redis: fast
    'dynamic_latency':        ['p(95)<400'],   // full PHP render: slower, but bounded
    http_req_failed:          ['rate<0.01'],
  },
};

// A small set of "content" URLs an anonymous crawler/reader would hit.
const PATHS = ['/', '/?p=1', '/?cat=1', '/hello-world/', '/?page_id=2'];

export function anonymous() {
  const path = PATHS[Math.floor(Math.random() * PATHS.length)];
  const res = http.get(`${BASE}${path}`);
  const status = res.headers['X-Cache-Status'] || 'NONE';
  cacheHitRate.add(status === 'HIT');
  anonLatency.add(res.timings.duration);
  check(res, { 'anon 200': (r) => r.status === 200 });
  sleep(Math.random() * 2);
}

export function loggedIn() {
  // a logged-in cookie forces $skip_cache=1 -> request is rendered live
  const res = http.get(`${BASE}/`, {
    headers: { Cookie: 'wordpress_logged_in_demo=1' },
  });
  dynamicLatency.add(res.timings.duration);
  check(res, {
    'dynamic 200': (r) => r.status === 200,
    'dynamic was NOT cached': (r) =>
      (r.headers['X-Cache-Status'] || 'BYPASS') !== 'HIT',
  });
  sleep(Math.random() * 3);
}
