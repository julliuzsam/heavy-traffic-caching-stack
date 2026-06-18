// k6-anon.js - peak cached-throughput test.
//
// Pure anonymous traffic, ramped hard, to find the ceiling when (almost)
// everything serves from the full-page cache. This is the number that lets a
// 4-vCPU box absorb hundreds of thousands of daily visitors: when nginx
// answers from Redis, PHP and MariaDB are barely involved.
//
// Run:  k6 run load/k6-anon.js

import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const cacheHitRate = new Rate('cache_hit_rate');

export const options = {
  scenarios: {
    peak: {
      executor: 'ramping-arrival-rate',
      startRate: 50,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 500,
      stages: [
        { duration: '30s', target: 500 },   // 500 req/s
        { duration: '1m',  target: 2000 },  // push to 2000 req/s
        { duration: '30s', target: 2000 },
        { duration: '20s', target: 0 },
      ],
    },
  },
  thresholds: {
    cache_hit_rate:   ['rate>0.95'],
    http_req_failed:  ['rate<0.01'],
    http_req_duration:['p(95)<80'],
  },
};

export default function () {
  const res = http.get(`${BASE}/`);
  cacheHitRate.add((res.headers['X-Cache-Status'] || 'NONE') === 'HIT');
  check(res, { '200': (r) => r.status === 200 });
}
