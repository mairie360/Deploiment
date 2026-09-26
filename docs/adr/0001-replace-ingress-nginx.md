# ADR 0001: Replace ingress-nginx

- Status: proposed (decision only, the migration is not implemented)
- Date: 2026-09-25
- Ticket: MAIR-228 (epic MAIR-216)

## Context

ingress-nginx is the only public entry point of every instance
(`bootstrap/appsets/ingress-nginx-appset.yaml`): k3s runs with Traefik
disabled, ServiceLB binds the controller's LoadBalancer Service to ports
80/443, cert-manager solves HTTP-01 challenges through
`ingressClassName: nginx`, and the NetworkPolicies admit traffic from the
`ingress-nginx` namespace (`global.ingressNamespace`).

Kubernetes SIG Network and the Security Response Committee announced on
2025-11-11 that ingress-nginx is retired: best-effort maintenance ended in
March 2026, the repository is archived, and there will be **no further
release, bug fix or security fix**
(<https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>).
MAIR-228 bumps the chart to its last release, 4.15.1 (controller v1.15.1),
which fixes CVE-2025-1974 ("IngressNightmare") and the other known CVEs, but
any vulnerability found from now on stays open. The Ingress API itself is not
removed; it is feature-frozen, and new work happens in the Gateway API.

What we actually use from ingress-nginx is small:

- host-based routing to the fronts and to Keycloak (`templates/ingress.yaml`,
  `templates/keycloak-ingress.yaml`, `pathType: Prefix`);
- TLS termination with cert-manager certificates;
- three annotations: `proxy-body-size: 50m`, `ssl-redirect`,
  `force-ssl-redirect`; controller config `use-forwarded-headers`,
  `ssl-protocols`, `hsts`; `externalTrafficPolicy: Local` for the client IP.

No snippet, auth, rewrite or canary annotation is used.

## Options

| Option | For | Against |
|---|---|---|
| **Traefik (bundled with k3s)** | Already shipped by k3s (re-enable it in ansible `k8s_node` or install the chart through an AppSet like today). Implements both Ingress and Gateway API. Ships an ingress-nginx annotation compatibility provider (Traefik v3.5+), so the existing Ingress objects can move with few changes. cert-manager HTTP-01 works with Ingress and Gateway API. | The k3s-bundled version follows the k3s release, not ours; installing it via Argo CD instead keeps the pin in this repo. Annotations differ natively (body size and redirects become Middlewares). |
| **Cilium Gateway API** | Cilium is already the CNI (ansible `k8s_node`), so no extra controller to operate; Gateway API is the upstream direction; Hubble would also see L7 at the edge. | Requires `kubeProxyReplacement: true` (today `false`, k3s keeps kube-proxy and ServiceLB) and Cilium's own LB/L2 announcement or host-network mode to bind 80/443: a CNI-level change on every machine, riskier to roll out and to roll back. |
| **Envoy Gateway / NGINX Gateway Fabric** | Pure Gateway API implementations, actively maintained. | One more component to learn and operate; no benefit over Traefik for our small feature set. |
| **F5 NGINX Ingress Controller** | Closest configuration model to ingress-nginx. | Different annotation set anyway (`nginx.org/*`), and it stays on the frozen Ingress API. |

## Decision (proposed)

Move to **Traefik, installed and pinned through an Argo CD ApplicationSet**
(same pattern as the current `ingress-nginx-appset.yaml`), and use this
migration to switch the chart from `Ingress` to **Gateway API**
(`Gateway` + `HTTPRoute`, cert-manager `gatewayHTTPRoute` solver). Keep the
Cilium Gateway API option for later, once kube-proxy replacement is adopted
for other reasons.

## Consequences / migration outline (not done in MAIR-228)

1. Add a Traefik AppSet (pinned chart, `externalTrafficPolicy: Local`,
   HSTS/TLS 1.2+ and 50 MiB body limit as Middlewares or entry-point options),
   namespace name wired into `global.ingressNamespace` and the NetworkPolicy
   and chainsaw tests that hard-code `ingress-nginx`.
2. Chart: render `Gateway`/`HTTPRoute` (or Traefik-class Ingresses as a first
   step), update `ingress.className`, `acme-solver-network-policy.yaml`,
   `scripts/verify.sh`, `scripts/hubble-flows.sh` and the e2e suite.
3. cert-manager: switch the ClusterIssuers' HTTP-01 solver
   (`bootstrap/cluster-addons/cluster-issuers.yaml`) to the new class/Gateway.
4. Roll out on `dev`, then `staging`, then `prod`; only one controller can
   own ports 80/443 through ServiceLB, so the switch is a short cut-over per
   machine, not a side-by-side run.
5. Remove `ingress-nginx-appset.yaml`.

Until then, ingress-nginx stays on 4.15.1 and should be watched for new
advisories (no upstream fix will come).
