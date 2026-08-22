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

It feeds `prev_*_image` back in so the apply changes capacity and nothing else.
Both empty and the literal `placeholder` are disqualifying: `placeholder` is the
`variables.tf` default and an unpullable reference, so an emptiness check alone
would let it through and the apply would replace the live slot's task
definitions with images ECS can never pull.

---

## Application

### `/health` vs `/ready`

`/health` checks database and Redis connectivity and is what ECS uses for task
health and what blue-green promotion polls. `/ready` always returns 200 and is
for load balancers gating traffic.

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
