import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 5 },
    { duration: '1m', target: 10 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

const base = __ENV.BASE_URL || 'http://localhost:8080';
const code = __ENV.SHORT_CODE;
if (!code) throw new Error('SHORT_CODE is required');
http.setResponseCallback(http.expectedStatuses(302));

export default function () {
  const response = http.get(`${base}/r/${code}`, { redirects: 0 });
  check(response, {
    'HTTP 302': (r) => r.status === 302,
    'correct Location': (r) => r.headers.Location === 'https://example.com/devops-lab',
  });
  sleep(0.2);
}
