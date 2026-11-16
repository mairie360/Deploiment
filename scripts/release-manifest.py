#!/usr/bin/env python3
"""Release manifests: the commit of every repo that makes a platform release (MAIR-1006).

A release of the platform (the global package X.Y.Z) is defined by `releases/<version>.yaml`, which
freezes the commit of each service repo's main when the release starts. The promotions are then
started with `-f sha=<sha of the manifest>`: a Renovate merge that lands on main during the release
is not promoted and does not block it. The manifest is also the central record of which service
versions form a release (`semver` filled in once a repo is in prod).

    scripts/release-manifest.py new <version> [--out releases]   # reads each main through `gh api`
    scripts/release-manifest.py check [--remote] [files...]       # CI; default: releases/*.yaml

`new` takes, for each repo, main's newest commit that has a pipeline (release journal and
`[skip ci]` commits left out, the rule of mairie360/CICD's promote resolve). `check` validates the
format (every repo exactly once, sha / dev_tag consistent, semver or null, file name = version) and,
with `--remote`, that every sha exists and is on its repo's main (`gh api .../compare`). Exit 0 /
1 (invalid manifest) / 2 (usage or API error).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = "mairie360"
# Every service repo of the platform, in promotion order (Email/Files are not maintained).
REPOS = [
    "Database",
    "Core_API", "Project_API", "Calendar_API", "Message_API", "ELearning_API", "Compliance_API",
    "BFF_user", "BFF_Project", "BFF_Calendar", "BFF_Message", "BFF_Elearning", "BFF_Dashboard", "BFF_Settings",
    "Login_Web_Service", "Administrator_Web_Service", "Projects_Web_Service", "Calendars_Web_Service",
    "Messages_Web_Service", "Elearning_Web_Service", "Dashboard_Web_Service", "Settings_Web_Service",
]
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
SKIP = re.compile(r"^docs\(release-journal\):|\[skip ci\]|\[ci skip\]", re.IGNORECASE)


class ApiError(Exception):
    pass


def gh(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode != 0:
        raise ApiError("gh api {}: {}".format(path, (result.stderr or result.stdout).strip()))
    return json.loads(result.stdout)


def newest_with_pipeline(repo):
    for commit in gh("repos/{}/{}/commits?sha=main&per_page=30".format(OWNER, repo)):
        subject = commit["commit"]["message"].splitlines()[0]
        if not SKIP.search(subject):
            return commit["sha"]
    raise ApiError("{}: no commit with a pipeline in the last 30 commits of main".format(repo))


def build(version, shas, now):
    return {
        "version": version,
        "created": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repos": {repo: {"sha": shas[repo], "dev_tag": "dev-" + shas[repo][:7], "semver": None} for repo in REPOS},
    }


def validate(path, manifest):
    """Problems of one manifest (empty list when valid)."""
    problems = []
    if not isinstance(manifest, dict):
        return ["{}: not a mapping".format(path)]
    version = manifest.get("version")
    if not isinstance(version, str) or not SEMVER.match(version):
        problems.append("{}: version must be X.Y.Z (quoted), got {!r}".format(path, version))
    elif os.path.basename(path) != version + ".yaml":
        problems.append("{}: the file must be named {}.yaml".format(path, version))
    unknown = set(manifest) - {"version", "created", "repos", "notes"}
    if unknown:
        problems.append("{}: unknown keys {}".format(path, sorted(unknown)))
    repos = manifest.get("repos")
    if not isinstance(repos, dict):
        return problems + ["{}: repos must be a mapping".format(path)]
    missing, extra = [r for r in REPOS if r not in repos], sorted(set(repos) - set(REPOS))
    if missing:
        problems.append("{}: missing repos {}".format(path, missing))
    if extra:
        problems.append("{}: unknown repos {}".format(path, extra))
    for repo, entry in repos.items():
        where = "{}: {}".format(path, repo)
        if not isinstance(entry, dict):
            problems.append(where + ": must be a mapping")
            continue
        sha = entry.get("sha")
        if not isinstance(sha, str) or not SHA.match(sha):
            problems.append(where + ": sha must be a full 40-character commit sha")
        elif entry.get("dev_tag") != "dev-" + sha[:7]:
            problems.append(where + ": dev_tag must be dev-{}".format(sha[:7]))
        semver = entry.get("semver")
        if semver is not None and not (isinstance(semver, str) and SEMVER.match(semver)):
            problems.append(where + ": semver must be X.Y.Z (quoted) or null, got {!r}".format(semver))
        if set(entry) - {"sha", "dev_tag", "semver"}:
            problems.append(where + ": unknown keys {}".format(sorted(set(entry) - {"sha", "dev_tag", "semver"})))
    return problems


def check_remote(path, manifest):
    problems = []
    for repo, entry in (manifest.get("repos") or {}).items():
        sha = entry.get("sha") if isinstance(entry, dict) else None
        if repo not in REPOS or not isinstance(sha, str) or not SHA.match(sha):
            continue
        try:
            status = gh("repos/{}/{}/compare/{}...main".format(OWNER, repo, sha)).get("status")
        except ApiError as error:
            problems.append("{}: {}: {} not found ({})".format(path, repo, sha[:7], error))
            continue
        if status not in ("ahead", "identical"):
            problems.append("{}: {}: {} is not on main (compare: {})".format(path, repo, sha[:7], status))
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    new = sub.add_parser("new")
    new.add_argument("version")
    new.add_argument("--out", default=os.path.join(ROOT, "releases"))
    chk = sub.add_parser("check")
    chk.add_argument("--remote", action="store_true")
    chk.add_argument("files", nargs="*")
    args = parser.parse_args(argv)

    if args.command == "new":
        if not SEMVER.match(args.version):
            print("version must be X.Y.Z", file=sys.stderr)
            return 2
        path = os.path.join(args.out, args.version + ".yaml")
        if os.path.exists(path):
            print("{} already exists: a release manifest is never rewritten".format(path), file=sys.stderr)
            return 2
        try:
            shas = {repo: newest_with_pipeline(repo) for repo in REPOS}
        except ApiError as error:
            print(error, file=sys.stderr)
            return 2
        manifest = build(args.version, shas, datetime.datetime.now(datetime.timezone.utc))
        with open(path, "w", encoding="utf-8") as out:
            out.write("# Release manifest (MAIR-1006): commit of each repo's main frozen when the release started.\n")
            out.write("# Promotions run with -f sha=<sha>; semver is filled in once the repo is in prod.\n")
            yaml.safe_dump(manifest, out, sort_keys=False, default_flow_style=False)
        print(path)
        return 0

    files = args.files or sorted(
        os.path.join(ROOT, "releases", name) for name in os.listdir(os.path.join(ROOT, "releases"))
        if name.endswith(".yaml"))
    problems = []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                manifest = yaml.safe_load(handle)
        except (OSError, yaml.YAMLError) as error:
            problems.append("{}: unreadable ({})".format(path, error))
            continue
        found = validate(path, manifest)
        if not found and args.remote:
            found = check_remote(path, manifest)
        problems += found
    for problem in problems:
        print("::error::" + problem if os.environ.get("GITHUB_ACTIONS") else problem)
    print("{} release manifest(s) checked, {} problem(s)".format(len(files), len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
