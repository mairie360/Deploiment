# ADR 0001: Replace ingress-nginx

- Status: **accepted** (MAIR-260). Proposed in MAIR-228; Traefik is
  implemented and each instance switches with the procedure below.
- Date: 2026-09-25
- Tickets: MAIR-228 (proposal), MAIR-260 (implementation), epic MAIR-216

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

## Decision

Move to **Traefik, installed and pinned through an Argo CD ApplicationSet**
(`bootstrap/appsets/traefik-appset.yaml`, chart 41.6.0 = Traefik v3.7.13),
keeping the chart on the `Ingress` API for now. **Gateway API** (`Gateway` +
`HTTPRoute`, cert-manager `gatewayHTTPRoute` solver) is the next step, on the
same Traefik, in a later ticket: switching controller and API at once would
make a failed rollout impossible to bisect. The Cilium Gateway API option
stays open for when kube-proxy replacement is adopted for other reasons.

### Where Traefik runs

k3s bundles a Traefik, and ansible `k8s_node` disables it
(`disable: [traefik]` in `/etc/rancher/k3s/config.yaml`). **It stays
disabled**: the bundled one follows the k3s release (its version changes with
every k3s bump, outside GitOps) and is configured through a `HelmChartConfig`
on each machine. Traefik is instead installed by Argo CD, with its chart
version pinned in `traefik-appset.yaml` and its values in
`bootstrap/values/traefik.yaml`, the same file `tests/e2e/run.sh` installs.

### One controller per machine

Both controllers publish a LoadBalancer Service on 80/443, and k3s ServiceLB
cannot bind a host port twice: a machine runs one or the other. The choice is
the Argo CD cluster label **`mairie360.fr/ingress`**, written by ansible
`k8s_instance_link` from the host variable `ingress_controller`
(`nginx` by default):

| Label | `ingress-nginx-appset.yaml` | `traefik-appset.yaml` |
|---|---|---|
| absent or `nginx` | installs ingress-nginx | - |
| `traefik` | - (deletes it) | installs Traefik |

Both AppSets set the `resources-finalizer.argocd.argoproj.io` finalizer on
their Applications, so a flip deletes the old controller's resources (and
frees 80/443) instead of orphaning them.

The instance's chart values say the same thing with
**`global.ingressController`** (`nginx` | `traefik`), from which the chart
derives everything controller-specific:

| | nginx | traefik |
|---|---|---|
| `ingressClassName` | `nginx` | `traefik` |
| HTTP -> HTTPS | `nginx.ingress.kubernetes.io/ssl-redirect` + `force-ssl-redirect` | web entrypoint redirect (301 for GET/HEAD, 308 otherwise) in `bootstrap/values/traefik.yaml`, priority 1; fronts routers on `websecure` only |
| body limit (`ingress.maxBodySizeMiB`, 50) | `proxy-body-size: 50m` | `buffering` Middleware (`maxRequestBodyBytes`), `router.middlewares` annotation |
| HTTP-01 solver class | annotation `acme.cert-manager.io/http01-ingress-ingressclassname: nginx` | same annotation, `traefik` (the shared ClusterIssuers keep `nginx` as default) |
| client `X-Forwarded-For` | `use-forwarded-headers: "false"` (MAIR-226) | `forwardedHeaders` with no `trustedIPs`, `insecure: false` |
| source IP | `externalTrafficPolicy: Local` | `externalTrafficPolicy: Local` |
| TLS | `ssl-protocols: TLSv1.2 TLSv1.3` | `TLSOption` default `minVersion: VersionTLS12` |
| NetworkPolicy source namespace | `ingress-nginx` | `traefik` |

Known difference: ingress-nginx sends HSTS by default, Traefik does not.
HSTS moves to MAIR-258 (with rate limiting).

The HTTP-01 challenge must not be caught by the HTTPS redirect: Traefik's
entrypoint redirect is pinned to priority 1, so the cert-manager solver
router (`Host(...) && Path(/.well-known/acme-challenge/<token>)`,
`pathType: Exact`, default priority = rule length) always wins on port 80.
The e2e suite proves issuance against Pebble (`tests/e2e/chainsaw/ingress`,
fresh challenges on every order); an extra run without the pinned priority
also succeeded on v3.7.13, so the pin is a guarantee rather than a fix.

## Migration procedure

One machine at a time, **dev -> staging -> prod**, each one only once the
previous one has run a day without trouble. On each machine the switch is a
short cut-over (a few minutes without ingress between the deletion of
ingress-nginx and Traefik taking 80/443), not a side-by-side run: do prod
in a quiet window.

For `<env>` (group `mairie360`; same for a client group):

1. **Before**: `./scripts/verify.sh <ctx> <env> <domain>` passes; note the
   certificate expiry (`kubectl -n mairie360-<env> get certificate`).
2. **Controller** (ansible): in `inventory/hosts.yml`, add
   `ingress_controller: traefik` to the instance host, then
   `ansible-playbook playbooks/site.yml --limit 'mairie360_argocd:mairie360_instances' --tags labels`.
   The same label can be set by hand on the Argo CD machine
   (`kubectl -n argocd label secret <cluster-secret> mairie360.fr/ingress=traefik --overwrite`),
   but keep the inventory as the source of truth. Argo CD deletes the
   `ingress-nginx-<env>` Application (and, through the finalizer, the
   controller) and creates `traefik-<env>`. Check:
   `kubectl -n traefik get pods,svc` (Service with the machine's IP as
   external IP) and `kubectl get ns ingress-nginx` (gone; if it is still
   there, delete it: the finalizer did not run).
3. **Chart** (this repo): in `clusters/mairie360/instances/<env>/values.yaml`,
   set `global.ingressController: "traefik"`, commit, push, let Argo CD sync
   (or `argocd app sync <env>`). The Ingress moves to class `traefik`, the
   body-size Middleware is created and the NetworkPolicies admit the
   `traefik` namespace.
4. **Verify**:
   - `curl -sI http://login.<domain>/` -> `301`, `Location: https://...`;
   - `./scripts/verify.sh <ctx> <env> <domain>` passes (certificates,
     reachability, closed ports);
   - force one renewal to prove HTTP-01 through Traefik:
     `cmctl renew -n mairie360-<env> <release>-mairie360-stack-fronts-tls`,
     then the Certificate is `Ready` again;
   - `curl -sk -H 'X-Forwarded-For: 1.2.3.4' https://login.<domain>/` from
     outside, and `kubectl -n traefik logs deploy/traefik` shows your real
     public IP, not `1.2.3.4`;
   - a request body above 50 MiB gets `413`.
5. **Rollback** (any step): set `ingress_controller: nginx` (or remove it),
   re-run the `--tags labels` command, and revert the values commit
   (`global.ingressController: "nginx"`). Argo CD deletes Traefik and
   reinstalls ingress-nginx 4.15.1; certificates are Secrets and survive
   both ways.

Steps 2 and 3 must happen together: between them, the Ingress still asks for
the class of the controller that is gone (404/no route), and applying step 3
first fails the sync on a machine without Traefik's Middleware CRD.

## After prod has switched

Once every instance of every group runs Traefik (no cluster secret left
without `mairie360.fr/ingress=traefik`):

1. Delete `bootstrap/appsets/ingress-nginx-appset.yaml` (separate PR). The
   platform app prunes the AppSet; it selects no machine anymore, so nothing
   else is removed.
2. Make `traefik` the default of `global.ingressController` and of ansible
   `ingress_controller`, drop the `nginx` branches of
   `templates/_helpers.tpl`, and switch the ClusterIssuers' default solver
   class to `traefik`.
3. Start the Gateway API ticket.
