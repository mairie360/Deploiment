// HTTP burst at a multiple of nominal traffic. Run from the disposable source machine:
//   k6 run -e BASE=https://login.staging.mairie360-eip.fr -e TARGET=/api/auth/login \
//          -e RPS=200 -e DURATION=120s --summary-export=attack-summary.json k6/attack.js
// Counts the answers by class so dos.py can check the service sheds with 429/413, not 5xx/timeouts.
import http from "k6/http";
import { Counter } from "k6/metrics";

const BASE = __ENV.BASE;
const TARGET = __ENV.TARGET || "/api/auth/login";
const BODY = __ENV.BODY || JSON.stringify({ email: "attack.user@example.invalid", password: "x", device_info: "dos" });
const METHOD = __ENV.METHOD || "POST";

const status = {
  "2xx": new Counter("status_2xx"),
  "429": new Counter("status_429"),
  "413": new Counter("status_413"),
  "5xx": new Counter("status_5xx"),
  timeout: new Counter("status_timeout"),
};

export const options = {
  scenarios: {
    burst: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RPS || 200),
      timeUnit: "1s",
      duration: __ENV.DURATION || "120s",
      preAllocatedVUs: 200,
      maxVUs: 1000,
    },
  },
};

export default function () {
  const res = http.request(METHOD, BASE + TARGET, BODY, {
    headers: { "Content-Type": "application/json" },
    timeout: "10s",
  });
  if (res.error_code === 1050 || res.status === 0) status.timeout.add(1);
  else if (res.status === 429) status["429"].add(1);
  else if (res.status === 413) status["413"].add(1);
  else if (res.status >= 500) status["5xx"].add(1);
  else if (res.status >= 200 && res.status < 300) status["2xx"].add(1);
}
