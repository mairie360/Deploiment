# Platform RGAA rate

The prod promotion of this repo checks the accessibility of the whole platform.

## Where the numbers come from

Every front is tested against the RGAA when it is promoted to prod (mairie360/CICD, `rgaa` gate).
Its GitHub release carries the result as the `rgaa-report.json` asset.

## Global rate

`scripts/rgaa-global.py` reads the report of each front pinned in `clusters/_base/prod.yaml`:

- a criterion is **not respected** by the platform when one front fails it;
- it is **respected** when every front that declares it passes it;
- otherwise it still needs a human check and is not counted.

Rate = respected / (respected + not respected), rounded down. Only automatically decided criteria
count: it is not an audit.

## Prod gate

The `rgaa-global` job of `Promote` (target prod) lists the failing criteria with their front, pages
and elements in the job summary, and stops the promotion below 50 %. A front released without a
report is listed and left out of the rate.

The minimum is the `rgaa_min_rate` input (default 50). A promotion may lower it for one release
only with `rgaa_exception`, the reason and the ticket of the fixes: the run refuses a lower minimum
without it, and writes the exception in its summary and as a warning.

## Release note

After a release reaches prod, run the `Release note` workflow with the version of
`releases/<version>.yaml`. It publishes, as the GitHub release `platform-v<version>`, a note in
French for the municipalities: rate, legal status (fully compliant at 100 %, partially from 50 %,
not compliant below), failing criteria and fronts without a measure. The script checks that the
note is accessible itself before publishing it.

Fixes to the fronts are tracked with one ticket per fix.
