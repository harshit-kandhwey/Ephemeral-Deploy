# Design decisions

Rationale for the non-obvious choices in this pipeline. Code comments state
what the code does; this file states why it is shaped that way. Comments link
here by anchor, e.g. `# See docs/design-decisions.md#fail-closed-state-reads`.

Scope: CI/CD workflows. Terraform and application sections are appended as
those layers are documented.

---

## CI

### Least-privilege workflow permissions

`ci.yml` grants `contents: read` at workflow level and each job that needs more
declares it locally: `contents: write` for the two auto-format jobs,
`security-events: write` for the SARIF upload, `actions: write` for the deploy
dispatch.

A workflow-level write grant would hand the elevated token to every job,
including the ones that run third-party actions over pull-request code. Job-level
grants keep the blast radius to the job that needs the privilege.

### Non-blocking security scanners

Grype, bandit, pip-audit, TFLint and Checkov all run with `continue-on-error`
or an equivalent soft-fail flag. None can fail a build.

The intent is visibility, not gating. A CVE in a base image is usually not
actionable in the moment, and a hard gate would block unrelated changes until
an upstream fix ships — which trains people to bypass the gate. Findings go to
the Security tab and should start a conversation instead.

Consequence to be aware of: a green check does **not** mean a clean scan. Read
the job log or the Security tab.

**"Validate each environment" is deliberately NOT in this set.** It runs
`terraform validate` + `terraform plan` per environment — basic
syntax/semantic correctness, not a security scanner with the CVE-noise
problem above. A config that doesn't even validate should fail CI outright,
so this step has no soft-fail flag. (It ran with `continue-on-error: true`
from the terraform-lint job's introduction until 2026-09-04 — an oversight,
not a decision; found during a live-deploy audit and fixed. If you're
tempted to re-add it, this paragraph is why not to.)

### Grype SARIF categories

Both images are built and scanned, each uploading under its own category
(`grype-api`, `grype-worker`).

GitHub code scanning keys results on `(category, ref)`. Without distinct
categories the second upload replaces the first, so adding the worker scan
would silently wipe the API findings rather than add to them.

**Do not rename these category strings.** The category is part of the analysis
key, so a rename orphans every existing alert: the old alerts can never
auto-close (nothing reports under their key again) while the new key opens a
fresh set. A previous rename took the open count from 778 to 1042 rather than
down, and recovery required deleting every Grype analysis across all refs.

Current baseline: 273 findings per image on `refs/heads/main`, 546 open alerts.
The two images produce identical findings — same base, same requirements. The
worker scan adds regression safety against future divergence, not new
information today.

### Deploy dispatch guard

`ci-summary` dispatches `deploy.yml` only for `dev`/`staging`/`main`, and never
for a dependency bump. Deploys cost real AWS spend, and a bumped action pin is
not a reason to rebuild an environment.

The guard covers all three ways a Dependabot change can land: squash (message
starts `chore(deps` — no closing paren, so it matches both the `deps` and
`deps-dev` groups), merge commit (`...from <org>/dependabot/...`), and a direct
push by the bot. `[skip deploy]` in the head commit is the manual escape hatch:
CI still runs in push context, so the branch ruleset's required check is
satisfied, but nothing deploys.

A `workflow_dispatch` run deploys only when its `deploy` input is checked. Note
that **re-running** a manual run replays the original inputs, so ticking the box
on a re-run has no effect — it takes a fresh dispatch.

### `!cancelled()` rather than `always()`

`ci-summary` gates on `!cancelled()`. With `always()`, a run cancelled by
`cancel-in-progress` would still reach the summary job, count its cancelled
dependencies as non-failures, and dispatch a deploy for a commit that has
already been superseded.

---

## Teardown (`cleanup.yml`)

### Bootstrap-owned resources survive cleanup

The destroy is `-target`ed rather than a bare `terraform destroy`. `module.iam`
(the OIDC provider and deploy role) and `module.ecr` are deliberately excluded:
they are created by `scripts/bootstrap.sh`, shared across environments, and
destroying them would break the pipeline's ability to deploy anything again.

The S3 state bucket is never deleted for the same reason — it holds every
environment's state.

### ECR images are left to the lifecycle policy

Cleanup does not delete images. Each repository's lifecycle policy keeps the
last 3 tagged images and expires untagged ones after a day.

Deleting images on teardown would force a full rebuild on the next deploy even
when application code is unchanged, and would break the artifact↔commit link
(image tags are commit SHAs) that the pipeline exists to demonstrate.

### RDS deletion protection is cleared before destroy

Prod sets `deletion_protection = true`. Terraform does not clear it — it simply
fails the destroy. `scripts/cleanup.sh` has always cleared it first; the
workflow now does the same, so the documented teardown path no longer needs a
manual `modify-db-instance` on its first attempt.

Safe for dev and staging, which set the flag to `false`: the describe returns
`False` and the step is a no-op. A missing instance reports `ABSENT` rather than
failing the job, so re-runs are safe.

The describe deliberately does **not** fail closed. A transient throttle turning
into a hard failure would abort the entire nightly dev teardown over a flag that
dev and staging never set — a worse outcome than the case it would protect.

### Deployment SSM parameters are workflow-owned

`/nexusdeploy/<env>/deployment/{active_slot,generation,prev_api_image,prev_worker_image}`
are written by the deploy workflow. None is a Terraform resource, and
`bootstrap.sh` does not create them either.

`terraform destroy` therefore never removed them, and a teardown left them
behind as orphans that misdirect the next deploy: a stale `active_slot` points
at a slot that no longer exists, and a stale `prev_*_image` stops the next
deploy from taking its documented first-deploy path. A dedicated cleanup step
deletes all four.

That step is gated on a teardown actually succeeding — the Terraform destroy
exiting zero, or the fallback script succeeding. If both failed, live slot
resources may still be serving, and deleting `active_slot` would make the next
deploy treat the environment as fresh and apply straight over the live slot.

### State deletion also clears the DynamoDB rows

Deleting the state object alone is not enough. Two rows outlive it in the lock
table:

- the **checksum digest** (`<bucket>/<key>-md5`) — a later `terraform init`
  fails with "checksum calculated for the state stored in S3 does not match"
  because the digest describes a state file that no longer exists;
- the **lock mutex** (`<bucket>/<key>`) — released after a clean destroy, but a
  killed or timed-out destroy leaves it held, blocking the next init with
  "Error acquiring the state lock".

Both are orphaned once the environment is gone, so removing them makes cleanup
self-healing. The state object is backed up to `backups/<env>/` before deletion,
and the step aborts if that backup fails.

### Prod teardown is gated, not forbidden

`cleanup.yml` accepts `environment=prod`, but the destroy job runs under the
`prod` GitHub environment and blocks on a required reviewer. That approval gate
is the guardrail — not the absence of the option.

There is deliberately no one-command local prod destroy. A manual teardown means
downloading prod state and running `terraform destroy` against it on purpose.

---

## Blue-green rotation

### Slot model

Staging and prod each run two complete ECS service sets, `slot1` and `slot2`.
A deploy targets whichever slot is **not** active, health-gates it, promotes it
by writing `active_slot` in SSM, then schedules the old slot to drain — 1 hour
for staging, 24 hours for prod.

The old slot is kept at capacity for that window so a rollback is an SSM write
and a capacity change, not a rebuild.

### The old slot stays at capacity through the apply

The apply that stands up the new slot also holds the old slot at capacity
(`keep_previous_slot_running`), so it keeps serving while the new slot boots
and health-checks. Without the overlap, a single apply would scale the old
slot to 0 while the new one is still inside its startPeriod — a real outage
window — and a rollback would then have to resurrect capacity Terraform
believes should already be 0.

Held `false` only on a first deploy: there is no previous slot, and the
standby slot's image is still the `variables.tf` placeholder default, so
overlapping it would ask ECS to run a task definition it can never pull.

The overlap is why the deploy apply, and the rollback apply below it, both
refuse to run when `prev_*_image` hasn't resolved to a real value: the old
slot is *live* for the whole apply, so an unresolved image would replace its
serving task definitions rather than merely fail to add a new one.

### `init_db` failure blocks promotion

A migration task that exits non-zero fails the promotion gate, the same as a
failed health check. Both fail the same way for the same reason: promoting a
slot with a broken schema or a service that can't reach its dependencies
ships a deploy that looks green while serving requests badly.

### Fail-closed state reads

Two reads decide destructive behaviour, and both fail closed.

**`terraform state list`** exits non-zero in two very different situations: no
state file exists, or the backend could not be read. Orphan reconciliation
(delete + adopt) must run in the first case and must never run in the second,
where it would reconcile live resources against an empty view. The workflow
matches the benign diagnostic on its **first line** exactly.

Matching a substring anywhere in the output is too loose — a backend, lock or
auth diagnostic that happens to quote the phrase would enable the destructive
path. Comparing the whole output is wrong in the other direction, since
Terraform prints the diagnostic plus three lines of advice, so an equality test
never matches and first deploys break again.

**The `active_slot` SSM read** treats only a genuine `ParameterNotFound` as "no
previous deploy". Swallowing every error made an `AccessDenied` or a throttle
indistinguishable from a fresh environment, so a transient IAM blip would target
`slot1` and redeploy over the live slot.

### Generation is written before the apply, not after promotion

The generation is the deploy-attempt epoch: the run id of the last deploy that
reached its `terraform apply`. It advances on **every** attempt, including
failures.

A generation that only advanced on success could not invalidate the drains that
a *failed* deploy endangers. The failing case: deploy B applies a newer
Terraform revision, fails its health gate and rolls back — but the rollback
apply keeps every infrastructure change B's revision carried. Deploy A's drain
is still pending, still sees A's generation as current, and its capacity-only
apply runs against A's older pinned revision, quietly reverting B's
infrastructure hours later.

### Promotion order

Within a promotion the writes are ordered: record the deployed images as
`prev_*_image`, then write `active_slot` last. The `active_slot` write is the
atomic cutover point, and everything it depends on is already committed when it
happens.

Reversed, a failure between the two would leave `active_slot` naming the new
slot alongside stale previous images, and the next deploy would resolve the
wrong rollback target.

### The drain is three jobs, not one

`drain-wait` → `drain-approve` → `drain-reclaim`, split for two independent
reasons.

**Concurrency.** Only `drain-reclaim` joins the `blue-green-<env>` group. The
guard reads `active_slot` and the apply acts on it moments later; without
serialisation, a deploy promoting in that window leaves the guard stale and the
apply scales the newly-live slot to zero. Terraform's DynamoDB lock does not
help — it covers the apply, not the preceding SSM read. Putting the multi-hour
sleep inside the group instead would block deploys for a day.

**Approval.** Only `drain-reclaim` is gated by `drain-approve`, which carries
the `environment:`. A job pending environment approval *holds* its concurrency
group: GitHub treats it as occupying the lock while it waits for a reviewer, and
a second run in the same group cannot even be approved until the first clears
([community discussion 17401](https://github.com/orgs/community/discussions/17401)).
With `environment:` and the group on one job, an unattended prod drain blocked
every prod deploy for as long as nobody clicked approve.

Splitting them keeps the protection rule intact — `drain-reclaim` still needs
`drain-approve` — while the lock is held only for the seconds the guard and
apply run. A prod deploy can proceed while a drain sits unapproved; when the
reviewer eventually approves, the guard re-reads SSM, sees the newer generation
and aborts. That is what the guard is for.

`drain-approve` also carries `MONITORING_ALLOWED_CIDR` and `ALERT_EMAIL` across
as job outputs, because environment-scoped `vars` do not resolve in
`drain-reclaim`, which has no `environment:`. Both are non-secret configuration;
no secret crosses the boundary.

### The drain guard closes an ABA hole

Comparing the active slot alone is not sufficient. Slots only alternate, so
after two further promotions `active_slot` is back to the expected value and a
slot comparison passes again — while the slot this drain was told to remove is
now the *newest* deploy's rollback target, still inside its own window.
Draining it there silently deletes that deploy's safety net.

The generation never repeats, so comparing it closes the hole. The guard also
refuses outright when any safety input is missing, rather than proceeding on
whatever it can still check: a partial-mode drain is how one ends up bypassing
the ABA check and applying Terraform from an unrelated revision.

### The drain reclaims capacity through Terraform

`desired_count` is not in the ECS module's `ignore_changes`, so Terraform is
authoritative over capacity. An `aws ecs update-service --desired-count 0` drain
is therefore drift: it works for minutes, then the next deploy's apply puts the
drained slot straight back to 1. An apply is the only durable form of this step.

The apply is pinned to the **commit the deploy ran**, not the branch. The job
fires hours later, so a default checkout would resolve whatever the branch points
at by then, and a supposedly capacity-only apply would ship every unrelated
infrastructure commit merged in the meantime.

### The ECS service is authoritative over task_definition too

Each service resource used to carry `ignore_changes = [task_definition]`,
commented "Managed by CI/CD" — but no such step existed anywhere in
`deploy.yml`/`deploy-blue-green.yml`; the apply above is the only thing that
ever sets it. `ignore_changes` only skips *updates*, so a service's live task
definition stayed pinned to whatever it was at creation, forever, no matter
how many new revisions Terraform registered afterward. This went undetected
since every prior real deploy created its services fresh (image already
correct at creation); it first surfaced the moment an *existing* service
(one already deployed once) was asked to take a new image — confirmed via
CloudTrail: the `UpdateService` call carried `desiredCount` but no
`taskDefinition` field at all. Removed, so this resource matches
`desired_count`'s already-documented model above: Terraform owns it, fully.

It feeds `prev_*_image` back in so the apply changes capacity and nothing else.
Both empty and the literal `placeholder` are disqualifying: `placeholder` is the
`variables.tf` default and an unpullable reference, so an emptiness check alone
would let it through and the apply would replace the live slot's task
definitions with images ECS can never pull.

---

## Dev deploy

### Dev orphan reconciliation is best-effort

Before each apply, a step deletes AWS resources that survive a failed cleanup
but never made it into Terraform state (log groups, pending-deletion secrets,
the monitoring IAM role) — Terraform cannot create something that already
exists under a different identity. A second step then imports whatever that
step left behind (or never touches, e.g. IAM roles and ECR repos) so the
apply doesn't fail with "already exists" either.

Both steps run unconditionally (`continue-on-error: true`), unlike the
blue-green fail-closed reads above. Dev has no equivalent guard because
getting it wrong costs much less: dev auto-destroys in 30 minutes, so a bad
reconciliation degrades one disposable environment rather than a long-lived
staging/prod slot carrying real traffic.

### `init_db` runs as a one-shot, non-blocking task

`init_db.py` creates the least-privilege `nexusapp` DB user and runs
`db.create_all()`. It runs as a standalone ECS Fargate task — the worker's
task definition with its command overridden — inside the VPC, so it reaches
private RDS the same way the app does. It is idempotent, so re-running it on
every deploy is safe and simpler than tracking whether it already ran.
`continue-on-error: true` because a failed init shouldn't block a deploy
whose schema is already in place from a prior run.

### Dev health gate covers all three services

The health gate is a single loop polling API, worker and beat together so
they share one time budget. Polling the API to its full timeout and then
sampling worker/beat once would false-positive as "degraded" whenever the
sidecars are still a few seconds behind a fast-healthy API — the one-shot
sample would land during their normal startup window. The blue-green health
gate uses the same shape.

Checking worker and beat matters: an earlier version checked only the API,
which let beat crash-loop on every deploy (it could not write its schedule
file into the root-owned `/app`) without the deploy ever reporting failure.
Neither container defines a health check, so both are gated on
`runningCount == desiredCount` instead — enough to catch a service that never
starts, though not a finer-grained failure.

The gate is deliberately non-blocking: failing the deploy job would trigger
`cleanup-on-failure`'s immediate teardown, destroying the environment before
anyone can look at it. It reports loudly instead, via a per-service status
row in the job summary.

---

## Terraform

### VPC interface endpoints replace NAT for ECS Fargate

Interface endpoints let ECS tasks in private subnets reach AWS APIs without
a NAT Gateway — cheaper (~$0.01/hr each vs. NAT's $0.045/hr) and avoids a
single NAT instance being a shared point of failure/throughput limit for
every private-subnet service. Required set for this stack: `ecr.api` (pull
auth), `ecr.dkr` (layer download), `logs` (CloudWatch streaming),
`secretsmanager` (secrets at task startup), `ssm` (parameter store), plus
the `s3` Gateway endpoint (ECR layer storage — free, no hourly charge,
routes over the AWS backbone instead of the endpoint ENIs).

`single_az_endpoints` puts every interface endpoint's ENIs in one AZ instead
of one-per-AZ, halving the per-ENI-per-AZ charge — a deliberate non-HA
trade-off for dev only, where workloads in the other AZ share that one ENI's
failure domain. staging/prod leave it `false` (AWS recommends ≥2 AZs for
endpoint HA).

### Bootstrap owns the deploy role identity

The GitHub OIDC provider, the `github-actions-deploy` role, and its two
inline policies are all created by `bootstrap.sh`, not Terraform. Terraform
imports each one (`ignore_changes = all` on every one of them) so they show
up in state and `terraform plan` doesn't propose recreating them, but it
never writes to them — every permission change goes through `bootstrap.sh`.
The second inline policy (`github-actions-deploy-2`) exists only because the
role's real policy exceeds the 10,240-char aggregate inline-policy limit
split across two resources; Terraform's copy is a placeholder so it has
something to track in state.

### Deploy role cannot modify its own permissions

The deploy role's policy grants it `iam:PutRolePolicy` and other role-write
actions scoped to `role/${project}-*` — which matches the deploy role
itself. An explicit `Deny` on those same actions, scoped to just this role's
ARN, closes the self-escalation path that would otherwise let anything able
to trigger a deploy rewrite the role's own policy toward full admin. `Deny`
always wins over `Allow` in IAM evaluation, so this is airtight regardless of
ordering; reads (`GetRole`, `GetRolePolicy`, used by every apply's import
blocks) stay allowed, and management of the per-environment ECS/task roles
(a different ARN) is untouched. Mirrored by `DenySelfModification` in
`bootstrap.sh`, which owns the live policy this Terraform resource only
imports for tracking.

### Container env strips the slot suffix and forces debug off

`ENV` passed to the containers is `development` only for `dev`; everything
else — including blue-green's `staging-slot1`/`prod-slot2` — resolves to
`production`. `config.py` only defines `development`/`production`/`testing`;
leaking a slot-suffixed value into `ENV` would `KeyError` at startup.

`FLASK_DEBUG` and `SQLALCHEMY_ECHO` are hardcoded off for every deployed
environment, including dev. `SQLALCHEMY_ECHO` logs every statement with its
bind parameters — bcrypt hashes, emails — straight to CloudWatch. Local
`docker-compose` keeps both on; the deployed path never does.

### Seed passwords are a separate secret from DB credentials

`init_db`'s demo-data passwords (`SEED_ADMIN_PASSWORD` etc.) live in their
own Secrets Manager secret, not alongside `DB_MASTER_PASSWORD`. That lets
demo logins be shared or rotated without exposing the master DB credential
(`GetSecretValue` can't be scoped to a single JSON key, so there's no way to
hand out one without the other from a shared secret), and only the
worker/init task definition is granted them — the API task definition never
sees them. Generated per environment by Terraform (`random_password`,
stable across applies), replacing the `"ChangeMe-*"` fallback passwords
`init_db.py` would otherwise use — visible in the public repo, not something
to actually rely on.

### Alarm notifications are wired unconditionally

The SNS topic routing alarm ALARM/OK transitions is created and wired
regardless of whether `alert_email` is set — the topic itself is free, email
delivery is free, and the alarms already bill (~$0.10 each) whether or not
anything is subscribed. A blank `alert_email` still creates the topic (alarms
show up in the SNS console); setting it just adds a mail subscription.

The topic is left on the AWS-managed SSE default (unencrypted), not a
customer-managed key: the built-in `alias/aws/sns` key's policy omits
`cloudwatch.amazonaws.com`, so encrypting with it would block CloudWatch from
publishing at all, and a real CMK is ~$1/month — not worth it for alarm
fan-out on a stack this size. Suppressed with a `checkov:skip` comment
carrying the reason inline (checkov reads that reason from the same line, so
it isn't relocated here the way other suppression rationale is).

### Task-shortfall alarm catches what CPU alarms can't

A service sitting at 0 running tasks reports no CPU — missing data, not high
data — so a CPU alarm stays green through it. That's exactly how a
crash-looping beat once went unnoticed: green deploy, green alarms, no
scheduled tasks running at all. A `desired - running` metric-math alarm
closes the gap.

Metric math instead of a plain threshold on `running`, because blue-green
idles a whole slot at `desired_count = 0` — a "running < 1" alarm would fire
permanently on the idle slot, where the shortfall is legitimately 0 - 0 = 0.

Prod-only, and not by preference: the underlying `RunningTaskCount`/
`DesiredTaskCount` metrics come from Container Insights, which the ECS module
enables only on prod as a cost trade-off. Dev and staging get deploy-time
coverage instead (the worker/beat checks in `deploy.yml`/
`deploy-blue-green.yml`), which catches a service that never starts but not
one that dies later. Enabling Container Insights on staging's cluster would
make this alarm apply there too with no change to this file.

### ALB is commented out, not deleted

The ECS module's ALB/target-group/listener wiring stays in the file,
disabled, rather than being removed: direct ECS task IPs are used instead
(no load balancer running, no ~$16/month ALB cost), and keeping the config
in place means enabling it later is uncommenting, not re-deriving the target
group and listener rules from scratch.

The ECS service's `deployment_controller` is `type = "ECS"`, not
`CODE_DEPLOY`: blue-green here is implemented at the two-full-service-set
level described in [Slot model](#slot-model), not via ECS/CodeDeploy's own
native blue-green primitive — the two mechanisms would be redundant.

---

## Application

### `/health` vs `/ready`

`/health` checks database and Redis connectivity and is what ECS uses for task
health and what blue-green promotion polls. `/ready` always returns 200 and is
for load balancers gating traffic.

Both are exempt from the default rate limit (200/day, 50/hour), and the
exemption is load-bearing, not defensive: ECS polls `/health` every 30s
(120/hour) and Prometheus scrapes `/metrics` every 15s (240/hour), both well
past 50/hour. A 429 on the container health check reads to ECS as an
unhealthy task, so an un-exempted limiter would get the task killed and
replaced by its own health check.

### Rate-limiter storage diagnostic is instrumentation for an open bug

`create_app` logs `Rate limiter storage: uri=<redacted> backend=<class>`
right after `limiter.init_app`, to answer a question ECS Exec being disabled
otherwise blocks: staging containers have logged flask-limiter's "using the
in-memory storage" warning even though `RATELIMIT_STORAGE_URI` resolves to a
real Redis URL — a case a local repro of `create_app("production")` has
never reproduced. In-memory storage means limits are per-Gunicorn-worker and
reset on restart, so the documented global limit silently isn't in force.
`backend=unset` in the logs would confirm it.

`limiter.storage` is a property guarded by `assert self._storage`, so it
raises `AssertionError`, not `AttributeError`, when storage is unset (the
normal state when rate limiting is disabled, as `TestingConfig` does) —
`getattr(..., None)` does not protect against an assertion, only a bare
`try`/`except` does. This distinction has broken 42 tests once already.

### Seeding fails closed outside local development

`seed_sample_data` refuses to run against a deployed database using default
`"ChangeMe-*"` passwords: outside `ENV == "development"`, every one of
`SEED_ADMIN_PASSWORD`/`SEED_MANAGER_PASSWORD`/`SEED_DEV_PASSWORD` must be
present (injected from the `seed-secrets` Secrets Manager secret via the
worker task definition) or the function raises rather than falling back to
the hardcoded values that are visible in this public repo.

The guard checks `!= "development"`, not `== "production"`. In practice
`ENV` is only ever `"development"` (local and deployed dev) or
`"production"` (deployed staging and prod — see `create_app`, which accepts
no other value), so the two checks are currently equivalent. `!=
"development"` is the more robust expression of intent: it stays correct
even if that environment-name mapping changes, where `== "production"`
would silently start accepting default credentials in a new non-dev,
non-prod environment.

### Celery Beat is a singleton

Beat always runs at `desired_count = 1`. Two Beat instances fire every scheduled
task twice. This holds across a blue-green overlap as well: during a rotation the
candidate slot's Beat starts only as the old slot's Beat is scaled to zero.

Beat writes its schedule database to `/tmp` rather than the working directory.
`COPY --chown` sets ownership on the copied *contents*, not on the directory
itself, so `/app` stays root-owned and a non-root Beat cannot create its
schedule file there.

Beat also sets `SKIP_INIT_DB=true`. It shares the worker entrypoint, and without
this both would race to initialise the database.

### Health check verifies the task definition, not just health status

Every service has ECS's own `deployment_circuit_breaker { enable = true,
rollback = true }`, alongside this workflow's own hand-rolled health-check
+ rollback in `deploy-blue-green.yml`. They can both be watching the same
deployment at once.

ECS's circuit breaker counts tasks that fail to reach `RUNNING` (default
threshold: `max(3, 50% of desired count)` — for this repo's desired counts
of 1, that floors to 3) and, on rollback, silently reverts the SERVICE to
its previous `COMPLETED` deployment — entirely inside ECS, no Terraform or
workflow call involved, no external signal beyond an EventBridge event this
repo doesn't subscribe to. If that fires while the workflow's own 7-minute
health-check loop is still polling, the loop would see the OLD (already
healthy) revision's tasks — matching running count, passing container
health — and had no way to tell that apart from the NEW revision actually
having become healthy. It would report `health_ok=true` and promote a slot
that's silently still running the old image.

Fix: the health check now also compares every running task's
`taskDefinitionArn` (captured right after the apply, before either rollback
mechanism can act) against the expected new revision, for API and both
sidecars. A self-reverted service fails this even with perfect counts and
health status.

Circuit breaker stays enabled rather than disabled to resolve the overlap —
it is Amazon's own fast, independent detector for "tasks can't even start,"
and losing that isn't free just because this workflow's own check now
closes the promotion-side gap. The two mechanisms can still both act on the
same failed deployment; that's fine, since only what actually happens to be
live when the workflow's own check runs determines whether promotion fires.

### GitHub vars containing quotes must cross $GITHUB_OUTPUT via env:, not raw ${{ }}

`echo "key=${{ vars.SOMETHING }}" >> $GITHUB_OUTPUT` looks safe and usually
is — until the var's own value contains a `"`. GitHub substitutes `${{ }}`
as literal text before bash ever parses the line, so `${{ vars.X }}`
expanding to `["1.2.3.0/24"]` turns the line into
`echo "key=["1.2.3.0/24"]" >> $GITHUB_OUTPUT` — three bash string tokens
concatenated with no space, and the inner `"` characters are consumed as
(unintended) quote delimiters rather than literal characters. The value
that lands in `$GITHUB_OUTPUT` silently loses its inner quotes:
`key=[1.2.3.0/24]` — not valid JSON.

`MONITORING_ALLOWED_CIDR` is stored as a JSON array (`["223.181.119.0/24"]`)
specifically so a plain-CIDR value and an already-JSON value can share one
normalization check downstream (`!= \[*`, wrap if not already bracketed).
`cleanup.yml`'s `drain-approve` → `drain-reclaim` relay hit exactly this:
the corrupted value still started with `[`, so the downstream wrap was
skipped, and Terraform got `[223.181.119.0/24]` as a bare, unquoted,
unparseable value. First real drain-reclaim ever run (2026-09-04) hit it
immediately — the old slot's apply errored before touching desired_count,
leaving it stuck at full capacity alongside the new slot: real duplicated
spend until caught.

Fix: pass the value through `env:` (an actual environment variable, not a
re-parsed shell token) and reference it as `$VAR` inside the echo string —
`$VAR` expansion inside double quotes does not re-parse the value's own
quote characters as syntax. `deploy-blue-green.yml`'s direct
`TF_VAR_monitoring_allowed_cidr: ${{ vars.MONITORING_ALLOWED_CIDR }}` reads
were never affected — that's a step-level `env:` mapping already, not a
value built into a bash command string via `echo`.
