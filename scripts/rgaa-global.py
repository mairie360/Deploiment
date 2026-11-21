#!/usr/bin/env python3
"""Platform-wide RGAA rate of the fronts deployed to prod.

Each front's prod release carries the `rgaa-report.json` of its RGAA gate (mairie360/CICD
`actions/release/accessibility-section`). This script reads the report of every front
pinned in the prod values and computes the official global rate: a criterion is invalid for the
platform when it is invalid on one front, valid when it is valid on every front that declares it,
and still to review otherwise; rate = validated / (validated + invalidated), rounded down to one
decimal. Only the automatically decided criteria count: it is a CI rate, not an audit.

    scripts/rgaa-global.py gate [--values clusters/_base/prod.yaml] [--min 50] [--summary <file>]
        Lists the failing criteria (front, pages, elements) and exits 1 below the minimum.
    scripts/rgaa-global.py note <version> [--values …] [--out <file>]
        Writes the accessible release note of the platform release <version> (releases/<version>.yaml),
        checked by `check_note` (exit 1 when the note itself is not accessible).

A front without a report (released before the reports were attached, or its RGAA gate did not run) is listed and
left out of the rate. With no report at all, the gate warns and passes: nothing to measure yet.
`--reports <dir>` reads `<dir>/<repo>.json` instead of the GitHub releases (tests, offline runs).
Exit 0 / 1 (below the minimum, or inaccessible note) / 2 (usage, values or API error).
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = "mairie360"
DEFAULT_VALUES = os.path.join(ROOT, "clusters", "_base", "prod.yaml")
DEFAULT_MIN = 50.0
# Image of each front -> its repository and the name the municipalities know it by.
FRONTS = {
    "login-front": ("Login_Web_Service", "Connexion"),
    "administrator-front": ("Administrator_Web_Service", "Administration"),
    "projects-front": ("Projects_Web_Service", "Projets"),
    "calendar-front": ("Calendars_Web_Service", "Agenda"),
    "message-front": ("Messages_Web_Service", "Messagerie"),
    "elearning-front": ("Elearning_Web_Service", "Formation"),
    "dashboard-front": ("Dashboard_Web_Service", "Tableau de bord"),
    "settings-front": ("Settings_Web_Service", "Paramètres"),
}
MAX_PAGES = 5
MAX_ELEMENTS = 3


class Error(Exception):
    pass


# ---------------------------------------------------------------- inputs

def prod_pins(values_path):
    """[(image, repo, label, tag)] of the fronts enabled in the prod values."""
    try:
        with open(values_path, encoding="utf-8") as f:
            values = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        raise Error("cannot read {}: {}".format(values_path, e))
    pins = []
    for name, cfg in sorted(((values.get("Fronts") or {}).get("instances") or {}).items()):
        if not isinstance(cfg, dict) or cfg.get("enabled") is False:
            continue
        image = str((cfg.get("image") or {}).get("repository", "")).rsplit("/", 1)[-1]
        tag = str((cfg.get("image") or {}).get("tag", ""))
        if image not in FRONTS:
            raise Error("front {} uses image {!r}, unknown to FRONTS in scripts/rgaa-global.py".format(name, image))
        if not re.match(r"^\d+\.\d+\.\d+$", tag):
            raise Error("front {} is pinned to {!r}, not a released version".format(name, tag))
        repo, label = FRONTS[image]
        pins.append((image, repo, label, tag))
    if not pins:
        raise Error("no front in {}".format(values_path))
    return pins


def usable(report):
    return isinstance(report, dict) and isinstance(report.get("criteria"), list)


def fetch_report(repo, tag, reports_dir, tmp):
    """The report attached to release v<tag> of repo, or None when it has none."""
    if reports_dir:
        path = os.path.join(reports_dir, repo + ".json")
    else:
        path = os.path.join(tmp, repo + ".json")
        result = subprocess.run(["gh", "release", "download", "v" + tag, "--repo", "{}/{}".format(OWNER, repo),
                                 "--pattern", "rgaa-report.json", "--output", path, "--clobber"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            message = (result.stderr or result.stdout).strip()
            # No asset matching / no such release: the front has no report. Anything else is an error.
            if re.search(r"no assets? (to download|match)|release not found|not found", message, re.IGNORECASE):
                return None
            raise Error("gh release download v{} of {}: {}".format(tag, repo, message))
    try:
        with open(path, encoding="utf-8") as f:
            report = json.load(f)
    except (OSError, ValueError):
        return None
    return report if usable(report) else None


def collect(pins, reports_dir=None):
    """[(image, repo, label, tag, report or None)]"""
    with tempfile.TemporaryDirectory() as tmp:
        return [(image, repo, label, tag, fetch_report(repo, tag, reports_dir, tmp)) for image, repo, label, tag in pins]


# ---------------------------------------------------------------- computation

def status(criterion):
    value = str(criterion.get("status", "")).replace(" ", "_")
    return value if value in ("validated", "invalidated", "to_review") else "to_review"


def criterion_key(cid):
    try:
        return tuple(int(p) for p in str(cid).split("."))
    except ValueError:
        return (999, str(cid))


def aggregate(fronts):
    """Global status of each criterion, the failures per front, and the rate."""
    statuses, failures = {}, {}
    for _, _, label, _, report in fronts:
        if report is None:
            continue
        for c in report["criteria"]:
            if not isinstance(c, dict) or "id" not in c:
                continue
            cid = str(c["id"])
            statuses.setdefault(cid, []).append(status(c))
            if status(c) == "invalidated":
                failures.setdefault(cid, []).append((label, [f for f in c.get("failures") or [] if isinstance(f, dict)]))
    result = {}
    for cid, values in statuses.items():
        if "invalidated" in values:
            result[cid] = "invalidated"
        elif all(v == "validated" for v in values):
            result[cid] = "validated"
        else:
            result[cid] = "to_review"
    validated = sum(1 for v in result.values() if v == "validated")
    invalidated = sum(1 for v in result.values() if v == "invalidated")
    to_review = sum(1 for v in result.values() if v == "to_review")
    rate = math.floor(validated * 1000 / (validated + invalidated)) / 10 if validated + invalidated else None
    return {"statuses": result, "failures": failures, "validated": validated, "invalidated": invalidated,
            "to_review": to_review, "rate": rate}


def legal_status(rate):
    """Wording of the RGAA conformity status (decree 2019-768) for a rate."""
    if rate is None:
        return "non évalué"
    if rate >= 100:
        return "totalement conforme"
    if rate >= 50:
        return "partiellement conforme"
    return "non conforme"


# ---------------------------------------------------------------- rendering

def code(text, limit=120):
    text = " ".join(str(text).split()).replace("`", "'")
    return "`{}`".format(text if len(text) <= limit else text[:limit - 1] + "…")


def cell(text):
    return " ".join(str(text).split()).replace("|", "/")


def pages_of(failures):
    pages = []
    for f in failures:
        state = str(f.get("state", "?"))
        if state not in pages:
            pages.append(state)
    return pages


def gate_summary(fronts, result, minimum):
    rate = result["rate"]
    lines = ["### Taux RGAA global de la plateforme", ""]
    measured = [f for f in fronts if f[4] is not None]
    if rate is None:
        lines.append("Aucun critère décidé automatiquement : taux non calculable.")
    else:
        lines.append("**{} %** ({} critère(s) validé(s) sur {} décidé(s) automatiquement, minimum {} %) : {}."
                     .format(rate, result["validated"], result["validated"] + result["invalidated"], minimum,
                             "porte passée" if rate >= minimum else "**porte refusée**"))
    lines.append("")
    lines.append("Fronts mesurés : {} sur {} ; critères à vérifier manuellement : {}."
                 .format(len(measured), len(fronts), result["to_review"]))
    missing = [f for f in fronts if f[4] is None]
    if missing:
        lines += ["", "Sans rapport RGAA (exclus du taux) : " + ", ".join(
            "{} `v{}`".format(repo, tag) for _, repo, _, tag, _ in missing) + "."]
    lines += ["", "#### Critères non conformes", ""]
    failing = sorted((cid for cid, s in result["statuses"].items() if s == "invalidated"), key=criterion_key)
    if not failing:
        lines.append("Aucun.")
    for cid in failing:
        lines.append("- **Critère {}**".format(cid))
        for label, failures in result["failures"][cid]:
            pages = pages_of(failures)
            lines.append("  - {} : {} élément(s) sur {}".format(
                label, len(failures), ", ".join(code(p) for p in pages[:MAX_PAGES])
                + (" et {} autre(s)".format(len(pages) - MAX_PAGES) if len(pages) > MAX_PAGES else "")))
            seen = []
            for f in failures:
                if f.get("target") not in seen:
                    seen.append(f.get("target"))
            for target in seen[:MAX_ELEMENTS]:
                lines.append("    - {}".format(code(target)))
            if len(seen) > MAX_ELEMENTS:
                lines.append("    - … {} autre(s)".format(len(seen) - MAX_ELEMENTS))
    return "\n".join(lines) + "\n"


def note(version, fronts, result, manifest):
    rate = result["rate"]
    decided = result["validated"] + result["invalidated"]
    lines = ["# Mairie 360 version {} : accessibilité".format(version), ""]
    if manifest.get("created"):
        lines += ["Release de la plateforme préparée le {}.".format(str(manifest["created"])[:10]), ""]
    lines += ["## En résumé", ""]
    if rate is None:
        lines.append("Aucune mesure automatique d'accessibilité n'est disponible pour cette version.")
    else:
        lines.append("Sur les {} critères du RGAA vérifiés automatiquement, {} sont respectés par toutes les "
                     "applications, soit un taux de {} %.".format(decided, result["validated"], rate))
        lines.append("")
        lines.append("{} autres critères demandent une vérification humaine : ils ne sont pas comptés."
                     .format(result["to_review"]))
    lines += ["", "## Statut au regard de la loi", ""]
    lines.append("D'après ces tests automatiques, la plateforme serait **{}** au RGAA "
                 "(totalement conforme à 100 %, partiellement conforme à partir de 50 %, non conforme en dessous)."
                 .format(legal_status(rate)))
    lines.append("")
    lines.append("Ce taux ne remplace pas un audit : la déclaration d'accessibilité de la commune doit reposer "
                 "sur un audit complet des 106 critères.")
    lines += ["", "## Applications mesurées", "",
              "| Application | Version | Taux de l'application |", "| --- | --- | --- |"]
    for _, _, label, tag, report in fronts:
        value = (report.get("rate") or {}).get("value") if report else None
        lines.append("| {} | {} | {} |".format(cell(label), tag,
                                               "{} %".format(value) if value is not None else "non mesuré"))
    missing = [f for f in fronts if f[4] is None]
    if missing:
        lines += ["", "Les applications non mesurées ont été publiées avant la mesure automatique ; elles ne "
                  "sont pas comptées dans le taux global."]
    lines += ["", "## Critères non respectés", ""]
    failing = sorted((cid for cid, s in result["statuses"].items() if s == "invalidated"), key=criterion_key)
    if failing:
        lines += ["| Critère RGAA | Applications concernées | Nombre de pages |", "| --- | --- | --- |"]
        for cid in failing:
            entries = result["failures"][cid]
            lines.append("| {} | {} | {} |".format(cid, cell(", ".join(label for label, _ in entries)),
                                                  sum(len(pages_of(f)) for _, f in entries)))
    else:
        lines.append("Aucun critère n'est en échec aux tests automatiques.")
    lines += ["", "## Méthode", "",
              "Chaque application est testée avant sa mise en production : ses pages sont ouvertes dans un "
              "navigateur, puis contrôlées automatiquement critère par critère. Un critère est respecté par "
              "la plateforme lorsqu'il l'est dans toutes les applications où il s'applique.", "",
              "Rapports détaillés : voir les releases des applications sur GitHub (fichier `rgaa-report.json`)."]
    return "\n".join(lines) + "\n"


# Accessibility of the note itself (it is published as is).
VAGUE_LINKS = re.compile(r"\[\s*(ici|cliquez ici|click here|here|lien|link|en savoir plus|plus)\s*\]\(", re.IGNORECASE)
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿⭐✅❌]")


def check_note(text):
    problems = []
    level, h1 = 0, 0
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        m = re.match(r"^(#{1,6})\s+\S", line)
        if m:
            new = len(m.group(1))
            h1 += new == 1
            if new > level + 1:
                problems.append("line {}: heading level {} after level {}".format(n, new, level))
            level = new
        if VAGUE_LINKS.search(line):
            problems.append("line {}: link text does not say where it goes".format(n))
        if re.search(r"\]\(\s*https?://[^)]*\)", line) and re.search(r"\[\s*https?://", line):
            problems.append("line {}: a URL as link text".format(n))
        if EMOJI.search(line):
            problems.append("line {}: emoji (read aloud literally, or carries meaning by image only)".format(n))
        if re.search(r"<span[^>]*color|style=", line, re.IGNORECASE):
            problems.append("line {}: information carried by colour or style".format(n))
        if line.startswith("|") and (n == 1 or not lines[n - 2].startswith("|")):
            following = lines[n] if n < len(lines) else ""
            if not re.match(r"^\|(\s*:?-{3,}:?\s*\|)+\s*$", following):
                problems.append("line {}: table without a header row".format(n))
    if h1 != 1:
        problems.append("the note must have exactly one level-1 heading, found {}".format(h1))
    return problems


# ---------------------------------------------------------------- CLI

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    gate = sub.add_parser("gate")
    gate.add_argument("--min", type=float, default=DEFAULT_MIN)
    gate.add_argument("--summary", default="")
    rel = sub.add_parser("note")
    rel.add_argument("version")
    rel.add_argument("--out", default="")
    rel.add_argument("--releases", default=os.path.join(ROOT, "releases"))
    for p in (gate, rel):
        p.add_argument("--values", default=DEFAULT_VALUES)
        p.add_argument("--reports", default="")
    args = parser.parse_args(argv)

    try:
        fronts = collect(prod_pins(args.values), args.reports or None)
    except Error as e:
        print("::error title=RGAA global::{}".format(e))
        return 2
    result = aggregate(fronts)

    if args.command == "gate":
        summary = gate_summary(fronts, result, args.min)
        print(summary)
        if args.summary:
            with open(args.summary, "a", encoding="utf-8") as f:
                f.write(summary)
        for _, repo, _, tag, report in fronts:
            if report is None:
                print("::warning title=RGAA global::{} v{} has no rgaa-report.json: left out of the rate".format(repo, tag))
        if result["rate"] is None:
            print("::warning title=RGAA global::no front has a decided RGAA criterion yet: nothing to gate")
            return 0
        if result["rate"] < args.min:
            failing = sorted((c for c, s in result["statuses"].items() if s == "invalidated"), key=criterion_key)
            print("::error title=RGAA global::platform rate {} % below the {} % minimum; failing criteria: {}"
                  .format(result["rate"], args.min, ", ".join(failing)))
            return 1
        return 0

    manifest_path = os.path.join(args.releases, args.version + ".yaml")
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        print("::error title=RGAA note::cannot read {}: {}".format(manifest_path, e))
        return 2
    text = note(args.version, fronts, result, manifest)
    problems = check_note(text)
    for p in problems:
        print("::error title=RGAA note::{}".format(p))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
