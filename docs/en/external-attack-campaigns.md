# External attack campaigns: rules of engagement

The frame every external attack campaign follows: what may be attacked, from where, with which
accounts, how fast, when to stop and who to warn. A campaign replays from the Internet what a
real attacker would try, black box (no account) and grey box (a Guest account), and checks
that nothing succeeds. French version: [`docs/fr/external-attack-campaigns.md`](../fr/external-attack-campaigns.md).

The repositories are public: no defence may rely on the implementation being secret, and the
scenarios assume the attacker has read this file.

## Target

| | |
| --- | --- |
| Target | **staging** only: `*.staging.mairie360-eip.fr` (the fronts, the only exposed services) |
| Never | prod (`*.prod.mairie360-eip.fr`), a client instance, dev, the Argo CD machines, Scaleway's own APIs and consoles |
| Why staging | it runs the release about to reach prod, with the prod settings (network policies, Traefik, sealed secrets), and holds no real user data |

Staging may be unavailable during a campaign window. It stays manually synced
(`deploiment_auto_sync_envs` is `dev` only): do not promote or sync it during a window, so
that a finding is tied to one known commit. Write that commit in the campaign report.

## Test accounts

Seeded by the Database migration (`seed_test_accounts`) on the instances whose values enable
`liquibase.testAccounts` (dev and staging). `clusters/_base/prod.yaml` forbids it, so a prod
instance that enables it fails to render, `scripts/seal-secrets.sh` refuses the password for
an environment named `prod`, and `scripts/verify.sh` fails when one is sealed there.

| E-mail | Role | Use |
| --- | --- | --- |
| `attack.admin@example.invalid` | `Admin` | checks only (what an administrator sees after an attack), never an attack source |
| `attack.maire@example.invalid` | `Maire` | access control scenarios |
| `attack.responsable@example.invalid` | `Responsable` | access control scenarios |
| `attack.user@example.invalid` | `User` | access control scenarios |
| `attack.user.b@example.invalid` | `User` | owner of the data the other accounts try to reach |
| `attack.user.c@example.invalid` | `User` | second victim, cross-user scenarios |
| `attack.guest@example.invalid` | `Guest` | the grey box posture |

All seven share one password. The `example.invalid` domain is undeliverable: no e-mail
journey (password reset, invitation) can be tested with them. Every deploy (the Liquibase
Job runs at each sync) puts them back in a known state: same password, role, active, no
first-connect step. Their projects, messages and events are kept: a scenario cleans up what it
created.

### Set the password (once per instance, dev then staging)

Prerequisite: the instance's `liquibase.image.tag` is a `liquibase-migrations` build of
Database that holds `repeatable/common/seed_test_accounts.sql` (any build from the Database
change that added the test accounts on). An older image ignores the parameter and creates
no account.

1. Generate a password (at least 16 random characters) and store it in the team vault
   (Scaleway Secret Manager of the organisation, entry `test-accounts-password` of the
   instance) and in the GitHub secret the campaign workflows read. It is never written in a
   ticket, a chat or this repository.
2. On the group's Argo CD machine, from `/opt/Deploiment`, seal it with the instance's
   other secrets (read the value without echoing it):

   ```bash
   read -rs TEST_ACCOUNTS_PASSWORD && export TEST_ACCOUNTS_PASSWORD
   # dev
   KUBECONFIG=/root/.kube/instance-dev.yaml ./scripts/seal-secrets.sh dev mairie360 dev
   # staging (with the staging password, read again)
   KUBECONFIG=/root/.kube/instance-staging.yaml ./scripts/seal-secrets.sh staging mairie360 staging
   ```

   Only its argon2id hash is sealed (`TEST_ACCOUNTS_PASSWORD` of `<env>-database-secret`).
   Later runs without the variable keep it; `--rotate` keeps it too.
3. Commit the new `secrets.yaml` through a pull request and merge: dev syncs by itself. For
   staging, promote, then sync staging by hand.
4. Check: sign in at `https://login.<env>.mairie360-eip.fr/` (`dev`, then `staging`) as
   `attack.guest@example.invalid`.

Until the key is sealed, the Liquibase Job logs that the test accounts are not seeded and
migrates normally.

## Source

| Scenarios | Source |
| --- | --- |
| Light: reconnaissance, DNS, authentication, access control, injection scans | GitHub-hosted runners (address not fixed, GitHub's published ranges) |
| Heavy: denial of service, long active scans | the disposable attack source machine of `mairie360/Infra` (root `attack-source/`): a Scaleway instance with a reserved flexible IP, outside every instance's private network, created for the window and destroyed after it |

The source address is written in the announcement. The attack source machine is created with
`scripts/tf.sh attack-source apply` and destroyed with `scripts/tf.sh attack-source destroy`
(Infra repository, with a team member's approval like any apply); its reserved IP is the
`source_ip` output.

## Window and announcement

- Announced in the team channel **at least 24 hours before**: start and end (date and hour,
  Europe/Paris), families of attack played, source address, staging commit, who runs it.
- Windows are on weekdays, 09:00 to 18:00, never during a demonstration, a mentor review or a
  release to prod.
- The person running the campaign stays at the keyboard for the whole window.

## Rate caps

| Family | Cap |
| --- | --- |
| Reconnaissance, DNS and e-mail | 1 request per second per host, ports scanned once per window |
| Authentication, sessions, access control, business logic | 5 requests per second |
| Active injection scans (ZAP) | 10 requests per second, 5 threads at most |
| Application denial of service | its own sub-window inside the campaign, raised by steps, stopped at the first breaking point (scenarios of that family) |

Network volumetric denial of service is not simulated: it is the host's protection.

## Stop criteria

Stop every scenario at once, then tell the team, when:

1. any other environment (dev, prod, a client instance, an Argo CD machine) receives
   campaign traffic or degrades during the window;
2. staging stays unavailable more than 15 minutes after the scenarios stopped;
3. the scenarios reach data that is not test data (real user, real document);
4. a secret or a credential is obtained: stop, write the finding, have it rotated before
   going on;
5. Scaleway sends an abuse notice or blocks the source address;
6. the end of the window is reached.

## Who to warn

- Before: the team, in the announcement.
- During, when a stop criterion is met: the team channel, then the person who can roll back
  or resync staging.
- After: the campaign report (one per family) and each finding in the vulnerability register,
  with its severity and its MAIR ticket.

## Host agreement (Scaleway)

Scaleway publishes no customer policy on intrusion or load testing (checked on 2026-11-26).
Before the first campaign, a written request goes to Scaleway support: the campaign above,
its source, its caps, and a confirmation of the anti-DDoS protection of each machine (control
E-05). Its answer is archived on the Jira ticket of the campaign frame and summarised here.

| Date | Request | Answer |
| --- | --- | --- |
| — | to be sent | — |
