#!/usr/bin/env python3
"""GDPR decisions vs configuration (MAIR-294, epic MAIR-284).

compliance/<org>/ holds the decisions of a mairie: register.yaml (processing record),
retention.yaml (periods), subprocessors.yaml, access.yaml, deadlines.yaml. For every instance of
the org that retention.yaml applies to, this script renders the umbrella chart with the
instance's values (scripts/instance-values.sh, like CI and the instances AppSet) and fails when the
configuration does not follow the decisions:

- the periods the retention CronJob writes into retention_policies (retention.policies);
- the restic retention of the backup CronJob (backup.retention);
- every external host of the rendered manifests (URLs, *_HOST variables, SMTP hosts) is a
  declared subprocessor, every egress CIDR belongs to one;
- the register is complete (purpose, legal basis, data, retention, known subprocessors);
- technical logs at most their maximum (1 year), files well formed.

Decisions without `validated` are proposals of Mairie 360: reported as pending, blocking with
--strict. Usage: scripts/check-compliance.py [--strict] [--org <org>] [--rendered <org>/<env>=<file>]
(--rendered skips helm for that instance: tests). Exit 0 / 1 (a mismatch) / 2 (invalid input).
"""
import argparse
import fnmatch
import ipaddress
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERIOD = re.compile(r"^(\d+) (day|days|month|months|year|years)$")
URL_HOST = re.compile(r"(?:s3:)?https?://([A-Za-z0-9.-]+)")
REGISTRIES = {"ghcr.io", "docker.io", "quay.io", "registry.k8s.io", "gcr.io", "mcr.microsoft.com"}
FILES = ["register.yaml", "retention.yaml", "subprocessors.yaml", "access.yaml", "deadlines.yaml"]


class Report:
    def __init__(self, strict):
        self.strict = strict
        self.errors = []
        self.pending = []

    def error(self, where, message):
        self.errors.append(f"{where}: {message}")

    def unvalidated(self, where, entry):
        if not isinstance(entry, dict) or not entry.get("validated"):
            self.pending.append(where)
        elif not (isinstance(entry["validated"], dict) and entry["validated"].get("date") and entry["validated"].get("by")):
            self.error(where, "validated must be {date, by}")


def months_days(period):
    """'6 months' -> (6, 0), '1 year' -> (12, 0), '10 days' -> (0, 10); None if invalid."""
    match = PERIOD.match(str(period).strip())
    if not match:
        return None
    n, unit = int(match.group(1)), match.group(2)
    if unit.startswith("year"):
        return (12 * n, 0)
    if unit.startswith("month"):
        return (n, 0)
    return (0, n)


def render(org, env):
    instance = os.path.join("clusters", org, "instances", env)
    files = subprocess.run(["./scripts/instance-values.sh", instance], cwd=ROOT, check=True, capture_output=True, text=True).stdout.split()
    args = ["helm", "template", "r", "./charts/mairie360-stack"]
    for f in files:
        args += ["-f", f]
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True).stdout


def documents(text):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)


def env_vars(node):
    if isinstance(node, dict):
        if "name" in node and "value" in node and isinstance(node.get("value"), str):
            yield node["name"], node["value"]
        for value in node.values():
            yield from env_vars(value)
    elif isinstance(node, list):
        for value in node:
            yield from env_vars(value)


def cronjob_script(docs, suffix):
    for doc in docs:
        if doc.get("kind") == "CronJob" and doc["metadata"]["name"].endswith(suffix):
            containers = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"]
            return "\n".join(s for c in containers for s in (c.get("args") or []) + (c.get("command") or []))
    return None


def external_hosts(docs):
    own = set()
    for doc in docs:
        if doc.get("kind") == "Ingress":
            for rule in doc["spec"].get("rules", []):
                if rule.get("host"):
                    own.add(rule["host"].split(".", 1)[1] if "." in rule["host"] else rule["host"])
    hosts = set()
    for doc in docs:
        if doc.get("kind") in ("Ingress", "Certificate", "CiliumNetworkPolicy", "NetworkPolicy"):
            continue
        for text in strings(doc):
            hosts.update(URL_HOST.findall(text))
            hosts.update(re.findall(r'"host"\s*:\s*"([A-Za-z0-9.-]+)"', text))
        for name, value in env_vars(doc):
            if name.endswith("_HOST") and re.fullmatch(r"[A-Za-z0-9.-]+", value):
                hosts.add(value)
    def internal(host):
        if "." not in host or host == "localhost" or host.endswith((".svc", ".svc.cluster.local", ".cluster.local", ".local")):
            return True
        try:
            return ipaddress.ip_address(host).is_private
        except ValueError:
            pass
        return any(host == d or host.endswith("." + d) for d in own) or host in REGISTRIES
    return sorted(h.lower() for h in hosts if not internal(h.lower()))


def egress_cidrs(docs):
    cidrs = set()
    for doc in docs:
        if doc.get("kind") == "CiliumNetworkPolicy":
            for rule in (doc.get("spec") or {}).get("egress", []) or []:
                cidrs.update(rule.get("toCIDR", []) or [])
                cidrs.update(c.get("cidr") for c in rule.get("toCIDRSet", []) or [] if c.get("cidr"))
    return cidrs


def check_org(org, report, rendered):
    base = os.path.join(ROOT, "compliance", org)
    data = {}
    for name in FILES:
        path = os.path.join(base, name)
        if not os.path.exists(path):
            report.error(f"compliance/{org}", f"{name} is missing")
            continue
        doc = yaml.safe_load(open(path, encoding="utf-8"))
        if not isinstance(doc, dict) or doc.get("version") != 1:
            report.error(f"compliance/{org}/{name}", "must be a mapping with version: 1")
            continue
        data[name] = doc
    if len(data) < len(FILES):
        return
    retention, subs, register = data["retention.yaml"], data["subprocessors.yaml"], data["register.yaml"]
    where = f"compliance/{org}/retention.yaml"

    tech = retention.get("technical_logs") or {}
    period, maximum = months_days(tech.get("period")), months_days(tech.get("maximum"))
    if period is None or maximum is None:
        report.error(where, "technical_logs.period and maximum must be '<n> day(s)|month(s)|year(s)'")
    elif period > maximum or maximum > (12, 0):
        report.error(where, f"technical_logs: {tech['period']} exceeds its maximum ({tech['maximum']}, at most 1 year)")
    report.unvalidated(f"{where} technical_logs", tech)
    report.unvalidated(f"{where} security_logs", retention.get("security_logs"))
    report.unvalidated(f"{where} archived_accounts_anonymization", retention.get("archived_accounts_anonymization"))
    report.unvalidated(f"{where} backups", retention.get("backups"))
    tables = retention.get("tables") or {}
    for table, entry in tables.items():
        if months_days((entry or {}).get("period")) is None:
            report.error(where, f"tables.{table}.period must be '<n> day(s)|month(s)|year(s)'")
        report.unvalidated(f"{where} tables.{table}", entry)

    names = set()
    for i, sub in enumerate(subs.get("subprocessors") or []):
        label = f"compliance/{org}/subprocessors.yaml subprocessors[{i}]"
        for key in ("name", "purpose", "location"):
            if not isinstance(sub.get(key), str) or not sub[key].strip():
                report.error(label, f"{key} is required")
        names.add(sub.get("name"))
        report.unvalidated(f"{label} ({sub.get('name')})", sub)
    patterns = [h for sub in subs.get("subprocessors") or [] for h in sub.get("hosts") or []]
    declared_cidrs = {c for sub in subs.get("subprocessors") or [] for c in sub.get("cidrs") or []}

    for entry in register.get("processings") or []:
        label = f"compliance/{org}/register.yaml {entry.get('id', '?')}"
        for key in ("purpose", "legal_basis", "retention"):
            if not isinstance(entry.get(key), str) or not entry[key].strip():
                report.error(label, f"{key} is required")
        if not entry.get("data"):
            report.error(label, "data must list the data categories")
        for name in entry.get("subprocessors") or []:
            if name not in names:
                report.error(label, f"subprocessor {name} is not in subprocessors.yaml")
        report.unvalidated(label, entry)
    if not register.get("processings"):
        report.error(f"compliance/{org}/register.yaml", "processings must not be empty")

    for i, d in enumerate(data["deadlines.yaml"].get("deadlines") or []):
        label = f"compliance/{org}/deadlines.yaml deadlines[{i}]"
        if not d.get("id") or not d.get("task") or months_days(d.get("every")) is None:
            report.error(label, "needs id, task and every ('<n> day(s)|month(s)|year(s)')")

    for env in retention.get("applies_to") or []:
        label = f"clusters/{org}/instances/{env}"
        key = f"{org}/{env}"
        try:
            text = open(rendered[key], encoding="utf-8").read() if key in rendered else render(org, env)
        except (subprocess.CalledProcessError, OSError) as error:
            report.error(label, f"cannot render the instance: {getattr(error, 'stderr', error)}")
            continue
        docs = documents(text)
        script = cronjob_script(docs, "-retention")
        if script is None:
            report.error(label, "the retention CronJob is not rendered (retention.enabled) while retention.yaml decides periods")
        else:
            applied = dict((t, p) for p, t in re.findall(r"INTERVAL '([^']+)' WHERE table_name = '([a-z0-9_]+)'", script))
            for table, entry in tables.items():
                want = months_days((entry or {}).get("period"))
                if table not in applied:
                    report.error(label, f"retention.policies has no period for {table} (decided: {entry.get('period')})")
                elif months_days(applied[table]) != want:
                    report.error(label, f"retention.policies.{table} is {applied[table]}, retention.yaml decides {entry.get('period')}")
            for table in sorted(set(applied) - set(tables)):
                report.error(label, f"retention.policies.{table} is not decided in retention.yaml")
        backups = retention.get("backups") or {}
        script = cronjob_script(docs, "-backup")
        if script is None:
            report.error(label, "the backup CronJob is not rendered (backup.enabled) while retention.yaml decides backups")
        else:
            for flag, key_name in (("daily", "keep_daily"), ("weekly", "keep_weekly"), ("monthly", "keep_monthly")):
                found = set(re.findall(rf"--keep-{flag} (\d+)", script))
                if found != {str(backups.get(key_name))}:
                    report.error(label, f"backup.retention keep {flag} is {', '.join(sorted(found)) or 'unset'}, retention.yaml decides {backups.get(key_name)}")
        for host in external_hosts(docs):
            if not any(fnmatch.fnmatch(host, p.lower()) for p in patterns):
                report.error(label, f"external host {host} is not a declared subprocessor (subprocessors.yaml)")
        for cidr in sorted(egress_cidrs(docs) - declared_cidrs):
            report.error(label, f"egress rule to {cidr} belongs to no declared subprocessor")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--strict", action="store_true", help="pending validations are blocking")
    parser.add_argument("--org", action="append", help="only this org (repeatable)")
    parser.add_argument("--rendered", action="append", default=[], help="<org>/<env>=<rendered manifests file>")
    args = parser.parse_args(argv)
    rendered = dict(r.split("=", 1) for r in args.rendered)
    base = os.path.join(ROOT, "compliance")
    orgs = args.org or sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    missing = [o for o in sorted(os.listdir(os.path.join(ROOT, "clusters"))) if not o.startswith("_") and o not in os.listdir(base)]
    report = Report(args.strict)
    for org in missing if not args.org else []:
        report.error(f"clusters/{org}", f"no compliance/{org}/ decisions for this org")
    for org in orgs:
        check_org(org, report, rendered)
    for message in report.errors:
        print(f"::error title=GDPR compliance::{message}")
    level = "error" if args.strict else "warning"
    for where in report.pending:
        print(f"::{level} title=GDPR compliance::{where}: not validated by the mairie yet")
    print(f"GDPR compliance: {len(report.errors)} mismatch(es), {len(report.pending)} decision(s) pending validation.")
    return 1 if report.errors or (args.strict and report.pending) else 0


if __name__ == "__main__":
    sys.exit(main())
