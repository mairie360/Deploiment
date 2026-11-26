// A legitimate agent's journey, run in parallel with the attack. Its p95 latency must
// stay under the frame's threshold while the instance is under load:
//   k6 run -e BASE=https://login.staging.mairie360-eip.fr -e COOKIE="accessToken=..." \
//          -e DURATION=120s --summary-export=legit-summary.json k6/legit.js
import http from "k6/http";
import { sleep } from "k6";

const BASE = __ENV.BASE;
const COOKIE = __ENV.COOKIE || "";

export const options = {
  scenarios: {
    agent: {
      executor: "constant-vus",
      vus: Number(__ENV.VUS || 2),
      duration: __ENV.DURATION || "120s",
    },
  },
  thresholds: { http_req_duration: [`p(95)<${__ENV.LEGIT_P95_MS || 2000}`] },
};

export default function () {
  http.get(BASE + "/session/me", { headers: { Cookie: COOKIE }, timeout: "10s" });
  sleep(1);
}
