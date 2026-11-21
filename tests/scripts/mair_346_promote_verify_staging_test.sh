#!/usr/bin/env bash
# MAIR-346: prod promotion depends on scripts/verify.sh passing against
# staging, run by the `verify-staging` job of .github/workflows/promote.yaml
# on the self-hosted runner of the group's Argo CD machine. Pins what makes
# that gate hold and keeps the runner away from untrusted code:
#   - promote.yaml has no trigger but workflow_dispatch;
#   - verify-staging runs on the Argo CD machine's runner, only for a prod
#     promotion that is not a rollback, after validate, checks out the
#     promoted commit without persisting the token, and runs verify.sh;
#   - `promote` needs verify-staging, and accepts it skipped only for staging
#     or a rollback (no more `staging_verified` checkbox);
#   - resolve refuses anything but staging's head for prod;
#   - no other workflow can land on that runner label, and actionlint knows it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import glob, os, sys, yaml

root = sys.argv[1]
LABEL = "mairie360-argocd-mairie360"
failed = False

def check(ok, label):
    global failed
    print(f"  {'OK  ' if ok else 'FAIL'}  {label}")
    failed |= not ok

wf = yaml.safe_load(open(os.path.join(root, ".github/workflows/promote.yaml")))
on = wf.get(True, wf.get("on"))  # PyYAML reads the `on:` key as True
check(list(on) == ["workflow_dispatch"], "promote.yaml is workflow_dispatch only")
check("staging_verified" not in (on["workflow_dispatch"].get("inputs") or {}),
      "no staging_verified checkbox any more")

jobs = wf["jobs"]
vs = jobs.get("verify-staging") or {}
check(bool(vs), "verify-staging job exists")
check(vs.get("runs-on") == ["self-hosted", "linux", LABEL], f"verify-staging runs on [self-hosted, linux, {LABEL}]")
cond = " ".join(str(vs.get("if", "")).split())
for part in ("github.event_name == 'workflow_dispatch'", "inputs.target == 'prod'", "!inputs.rollback",
             "needs.validate.result == 'success'"):
    check(part in cond, f"verify-staging if: {part}")
check({"resolve", "validate"} <= set(vs.get("needs") or []), "verify-staging needs resolve and validate")
check((vs.get("permissions") or {}) == {"contents": "read"}, "verify-staging token is read-only")
steps = vs.get("steps") or []
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
check(bool(co) and (co[0].get("with") or {}).get("persist-credentials") is False,
      "verify-staging checkout does not persist the token")
check(bool(co) and "needs.resolve.outputs.sha" in str((co[0].get("with") or {}).get("ref")),
      "verify-staging checks out the promoted commit")
check(any("./scripts/verify.sh" in str(s.get("run", "")) and "staging" in str(s.get("run", "")) for s in steps),
      "verify-staging runs scripts/verify.sh against staging")
check("instance-staging" in str((vs.get("env") or {}).get("KUBECONFIG", "")),
      "verify-staging uses the staging kubeconfig only")

pr = jobs["promote"]
check("verify-staging" in (pr.get("needs") or []), "promote needs verify-staging")
pcond = " ".join(str(pr.get("if", "")).split())
check("needs.verify-staging.result == 'success'" in pcond, "promote accepts a passed verify-staging")
check("needs.verify-staging.result == 'skipped' && (inputs.target != 'prod' || inputs.rollback)" in pcond,
      "promote accepts a skipped verify-staging only for staging or a rollback")

run = jobs["resolve"]["steps"][1]["run"]
check('[ "$TARGET" = "prod" ] && [ "$SHA" != "$(git rev-parse origin/staging)" ]' in run,
      "resolve refuses anything but staging's head for prod")
check("staging_domain" in (jobs["resolve"].get("outputs") or {}), "resolve outputs the staging domain")

# No other workflow may target the runner (a pull_request job naming the label
# would run fork code on the Argo CD machine).
others = []
for p in glob.glob(os.path.join(root, ".github/workflows/*.y*ml")):
    if os.path.basename(p) != "promote.yaml" and LABEL in open(p).read():
        others.append(p)
check(not others, f"no other workflow names {LABEL} {others or ''}")
lint = yaml.safe_load(open(os.path.join(root, ".github/actionlint.yaml")))
check(LABEL in lint["self-hosted-runner"]["labels"], ".github/actionlint.yaml declares the runner label")
sys.exit(1 if failed else 0)
PY
