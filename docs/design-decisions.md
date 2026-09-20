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

### Secret scanning is the one blocking scanner

`secrets-scan` (gitleaks, `ci.yml`) is deliberately **not** on the soft-fail
list above. It runs the CLI directly (a pinned release tarball, no third-party
Action) against full commit history, no path gating — a credential can land
in any file type, and this repo has no GitHub org, so the `gitleaks-action`
wrapper's license requirement (org use only) doesn't apply either way; the
direct-CLI approach just sidesteps the question rather than relying on that.
A real secret has no "wait for an upstream fix" case the way a base-image CVE
does — it's actionable the moment it's found (rotate it) — so this one fails
the build and gates `ci-summary` like `workflow-lint` does.

### Bandit scans `app/src/` only, deliberately, not `app/tests/`

`ci.yml`'s bandit step was `bandit -r app/src/ -ll -x app/src/tests/` — a
dead exclusion flag, since tests live at `app/tests/`, never
`app/src/tests/`. Fixing the stale path could mean either removing the
dead flag (scope stays `app/src/` only) or actually including
`app/tests/` in the scan. Chose the former, deliberately, not by default:
test fixtures routinely build known-bad states on purpose — hardcoded
credentials matching a documented default, malformed input crafted to hit
a specific validation branch — bandit has no way to distinguish
"intentional test fixture" from "shipped bug," so scanning tests trades a
small amount of real signal for a larger amount of noise that trains
reviewers to skim past bandit findings. If `app/tests/` is ever added to
the scan, expect to also add a project-specific `.bandit`/`# nosec`
baseline for the intentional cases, not just append the path.

### Local coverage command must mirror CI's `--cov-fail-under`

`pytest-cov`'s CLI flag overrides any config-file value (see
`.claude/rules/testing.md`), so the flag itself has to be copied wherever
the test command is documented, not just set once in `ci.yml`. It had
drifted out of `CONTRIBUTING.md` and two spots in `Readme.md` after the
60→85 bump (`#coverage-omit-list-is-a-reachability-boundary`) — a
contributor running the documented local command would see it pass at,
say, 87%, then watch CI fail the same code if it happened to sit at 84%.
Fixed to `--cov-fail-under=85` everywhere the command is documented.

### Drift detection needs an explicit liveness gate

`drift-detect.yml` runs `terraform plan -refresh-only` on a schedule against
all three environments. Verified live 2026-09-05: run this against an
environment with an empty or absent state (the normal condition here — dev
auto-destroys in 30min, staging/prod are torn down manually) and it does
**not** cleanly report "no drift" — it hard-errors, e.g.
`module.vpc.public_subnet_ids[0]` is an invalid index because the list is
empty. `-refresh-only` still evaluates the whole config graph, index
expressions included, even though it only ever diffs state-vs-live-read. So
each environment is gated on `terraform state list | wc -l` first, and skips
cleanly at 0 — checking is only meaningful once something is actually
deployed.

The job intentionally omits `environment:` (which would otherwise trip
prod's required-reviewer gate on a read-only job) and passes placeholder
values for `api_image`/`worker_image`/etc., same as `ci.yml`'s
terraform-lint validate step — safe here because `-refresh-only` never
proposes a change driven by a config/var difference (an add, delete, or
replace), only real drift between last-recorded state and a fresh live
read. That specific claim is untested against a populated state, since
nothing was deployed at the time this was written — recheck the first time
it runs for real.

### Deploy-by-digest, not by tag

`push-image` (`deploy.yml`) still tags images `:$TAG` (the commit SHA) and
`:latest` for humans browsing ECR, but the `api_image`/`worker_image`
outputs Terraform actually receives are `repo@sha256:...` digest
references, resolved right after the push via `aws ecr describe-images
--image-ids imageTag=$TAG`. A tag is a mutable pointer — a re-run of this
workflow for the same commit rebuilds and re-pushes the same `:$TAG`,
which can legitimately produce different bytes (a base image moved under
it) without the tag string changing at all. The digest this run resolved
is exactly the bytes that were built, scanned, and about to be deployed;
nothing after this point can silently swap them out from under it. Same
change applied to the "infra-only deploy" path (`current_images` in the
`setup` job) — it now resolves the most recently pushed image's digest
directly rather than reconstructing a tag string and filtering out
`latest`, which was needed only because tag names are ambiguous and isn't
needed at all once digest is the thing being resolved.

Every consumer downstream (`deploy-blue-green.yml`, the `prev_api_image`/
`prev_worker_image` SSM parameters, the ECS module's `image = var.api_image`)
already treated this value as an opaque string, so this was a
source-of-truth change only — no other file needed to change.

### Distroless runtime images

Both `app/Dockerfile` and `app/Dockerfile.worker`'s runtime stage moved from
`python:3.11-slim` to `gcr.io/distroless/python3-debian12:nonroot` — no
shell, no package manager, no coreutils; only the Python interpreter and
glibc. Verified locally (built and ran all three images — api, worker, beat
— against real postgres/redis containers, 2026-09-05) rather than assumed,
because this class of change breaks in ways that only show up at runtime,
not at build time. Two real breaks found and fixed along the way:

1. **A copied venv's console scripts don't survive the base-image switch.**
   `python -m venv` bakes the BUILDER stage's absolute python path into
   `bin/python`'s symlink target and every console script's shebang
   (`bin/gunicorn`, `bin/celery`). Copying `/opt/venv` into a distroless
   stage keeps those pointing at a path (`/usr/local/bin/python`) that
   doesn't exist there — `exec` fails with "no such file or directory" even
   though the file is present, because the interpreter behind its shebang
   isn't. Fixed by installing with `pip install --target=/opt/deps` instead
   of a venv (no interpreter-relative indirection — just importable
   packages on `PYTHONPATH`), and invoking everything as `python3 -m
   <module>` instead of a console-script path. This also means the
   distroless base's own default `ENTRYPOINT ["/usr/bin/python3.11"]` is
   kept rather than reset — every CMD/`command` override here is a list of
   *arguments to that entrypoint* (a script path, then its own args), not a
   standalone program name. `entrypoint_worker.py` is passed this way too;
   it isn't executable and has no meaningful shebang of its own for the
   same reason (no shell/`env` to resolve one via PATH).

2. **A builder/runtime Python patch mismatch broke a version-gated import.**
   `redis-py`'s `asyncio/connection.py` picks `async_timeout` vs stdlib
   `asyncio.timeout` based on `sys.version_info` at **runtime**, but pip's
   `python_full_version < "3.11.3"` marker for the `async-timeout`
   dependency is evaluated at **build time**, against the builder image's
   Python. The builder (`python:3.11-slim`, a floating tag) resolved to
   3.11.15 here; the distroless runtime is pinned to 3.11.2. Marker said
   "runtime will be >= 3.11.3, skip installing this" — wrong, because the
   two stages don't share a Python. Fixed by adding `async-timeout` to
   `requirements.txt` unconditionally (harmless dead weight on a runtime
   that doesn't need it). The general hazard outlives this one instance:
   **any package with a version-gated import is a latent break waiting for
   the day the builder and runtime base images' Python patch versions drift
   apart** — worth remembering before adding a new dependency, not just
   fixed once here.

Consequences accepted, not fixed: ECS Exec (now built, see
`#ecs-exec-and-the-distroless-no-shell-constraint`) drops into a `python3`
REPL instead of a shell, since there's nothing else in the image to exec
into. `docker-compose.yml`'s `beat` service and the ECS module's
`aws_ecs_task_definition.beat` both had their command override updated to
route through `/entrypoint_worker.py` first, for the same
ENTRYPOINT-is-python3 reason as above.

**The rule stated above was violated three times despite being documented
here already.** `deploy-blue-green.yml`'s `run-task` overrides for
`init_db` and `smoke_test`, and `cleanup.yml`'s for `queue_depth_check`,
all set `"command":["python","-m","src.X"]` — a leading `"python"` that
this section's own rule says shouldn't be there (the array is arguments to
the already-`python3` entrypoint, not a standalone command name). Verified
directly by running the real `gcr.io/distroless/python3-debian12` base
image locally with that exact override shape:
`/usr/bin/python3.11: can't open file '//python': No such file or
directory` — a real, reproducible failure, not a theoretical one. Fixed to
`["-m","src.X"]` in all three places, matching `beat`'s own
`/entrypoint_worker.py`-first command, which was already correct. The
`init_db` override predates this session and had reportedly been
"verified against real AWS" in an earlier pass — whether that verification
happened before this exact override string existed, or the failure went
unnoticed under `continue-on-error`, wasn't established; either way, this
exact command shape was broken as written and is now fixed and verified
locally against the real base image, not just reasoned about.

### Image signing and SBOMs

`push-image` (`deploy.yml`) signs both images with cosign and attaches an
SBOM, right after resolving their digests (see
#deploy-by-digest-not-by-tag — signing targets the digest, not the mutable
tag). Keyless: no key material anywhere in this repo or its secrets. cosign
gets a short-lived certificate from Fulcio using the job's own GitHub
Actions OIDC token (`id-token: write`, already needed for ECR auth), and
records the signature in Rekor's public transparency log — both free, no
AWS resource, no ongoing cost. The `~$1/mo` alternative would be a
KMS-backed key instead of keyless; not used here.

Verified locally before wiring this in (2026-09-05): a full sign → generate
SBOM (syft) → attest → verify-attestation round trip against a real
(ephemeral, local, non-ECR) registry, using a locally generated key pair —
key-based rather than keyless, since keyless needs a real CI-issued OIDC
token that only exists inside an actual GitHub Actions run. The keyless
handshake itself is the one part of this that can only be proven by
watching it actually happen on a real deploy.

One real finding from that local test: a small dummy `cosign attest`
predicate uploads in seconds, but the first attempt at attesting a full,
real SBOM (~185KB, spdx-json) appeared to hang past a 120s window with a
large volume of repeated output. A second attempt, with a longer timeout,
completed cleanly in a few seconds — almost certainly one-time TUF
trust-root initialization compounding with the larger upload on that first
run, not a hard payload-size limit. Documented rather than silently
retried-around, in case the first real deploy's `Sign images and attach
SBOMs` step runs unusually long — that would be why, and it's expected to
be fast on every run after the first.

`cosign attach sbom` (a separate, older subcommand) was deliberately not
used — cosign's own CLI flags it as deprecated in favor of SBOM
attestations, which is what `cosign attest --type spdxjson` above already
does.

### Staging joined dev in the nightly teardown sweep

`cleanup.yml`'s `destroy` job was single-environment (`github.event.inputs
.environment || 'dev'` — a scheduled run has no `inputs`, so this always
meant dev). It's now a `matrix.environment` job: a `schedule` trigger
expands to `["dev","staging"]`, a manual dispatch still expands to exactly
the one environment chosen. Prod is never in the scheduled set — its
teardown stays manual-dispatch-only and gated behind the `prod`
environment's required reviewer, per #prod-teardown-is-gated-not-forbidden
and CLAUDE.md's "prod teardown is not symmetric with dev/staging" note.

This is a policy change, not just plumbing: staging was "manual destroy"
(see the branch → environment table), meaning nothing tore it down on its
own. [[aws-budget-constraint]] already establishes that staging should
never be left up for an extended, unsupervised period anyway ("no 'leave it
up to poke around' sessions") — this closes the gap between that stated
policy and what actually enforces it, the same way dev's existing nightly
sweep is a safety net for a forgotten 30-minute-TTL cleanup that didn't
fire, not the primary mechanism. Concretely: staging left running past
midnight UTC is now torn down by the next day regardless of why the
`drain_minutes=0` verification pattern wasn't followed for it.

The destroy logic itself needed no per-environment changes — the same job
body was already exercised for staging via manual dispatch (this session's
own B6 teardown verification used exactly this path), including the
`deployment/*` SSM param cleanup, which is already conditioned on
`env.TF_ENV == "staging" || "prod"`. Validated with `actionlint` (not just
YAML parsing — it understands GitHub Actions expression/matrix semantics
specifically), clean across every workflow file touched this session.

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

### Post-promotion smoke test

`Health check new slot` only proves the candidate is alive: container-level
`HEALTHY` status, which itself is just `/health` (DB + Redis connectivity).
It cannot catch a broken *route* — a bad migration that leaves the schema
technically queryable but wrong for a real endpoint, a blueprint that failed
to register, a rate-limiter misconfiguration — because none of those affect
`/health`'s own narrow check.

`app/src/smoke_test.py` closes that gap by actually calling
`POST /api/v1/auth/login` with the seeded admin account and asserting a real
`access_token` comes back — exercising password verification, JWT signing,
and the full blueprint/rate-limiter stack in one request. Login has no side
effect, so it's safe to run on every gated deploy, not just the first.

Runs only when `run_init_db` is true (staging) — prod never seeds through
this pipeline (seeding fails closed outside `development`, see
`#seeding-fails-closed-outside-local-development`), so prod has no seeded
admin account to log in with yet; gating the smoke test on the same input
that gates seeding keeps the two consistent instead of inventing a second
"is seeding expected here" condition. Its outcome feeds the same promotion
gate as `init_db` and health (`steps.smoke_test.outcome != 'failure'`),
`continue-on-error: true` so a failure surfaces cleanly instead of aborting
the job mid-step.

Deliberately **not** run via `aws ecs execute-command`: the api/worker
images are distroless (`#distroless-runtime-images`) — no shell — and
whether ECS Exec's non-interactive command path behaves correctly against a
shell-less container isn't something this project has verified against real
AWS (the AWS CLI's `execute-command` is documented as needing an
interactive session; how it tokenizes and runs a multi-argument command
without `/bin/sh` to parse it is genuinely unclear without a live test).
Instead it runs the same way `init_db` already does — a `run-task` command
override on the worker task definition — a mechanism this pipeline has
already proven end-to-end, reusing `SEED_ADMIN_PASSWORD`, which is already
injected into the worker container from Secrets Manager. The target's
private IP is resolved runner-side (`list-tasks` → `describe-tasks` for the
ENI → `describe-network-interfaces` for the IP) since the ALB is disabled
and nothing outside the VPC can reach a task IP directly; the smoke-test
task reaches it because the API security group allows ingress on 5000 from
the whole VPC CIDR, not just a specific security group (see
`terraform/modules/security-groups`), so no SG change was needed.

### ECS Exec and the distroless no-shell constraint

`enable_execute_command` is now set on the api and worker services
(`var.enable_execute_command`, default `true`) purely as a general-purpose
debugging capability — it costs nothing when unused (the SSM channel only
opens for the duration of an actual `aws ecs execute-command` call, no idle
agent or per-hour charge) and needs the task role to allow
`ssmmessages:CreateControlChannel`/`CreateDataChannel`/`OpenControlChannel`/
`OpenDataChannel` (`terraform/modules/iam`'s `ecs_task_exec` policy — scoped
to those four actions only; `Resource = "*"` is the AWS-documented shape for
this specific action set, not a broad grant by choice).

Not used for the post-promotion smoke test above, and not verified against
real AWS as an interactive debugging tool either — both because the
api/worker images are distroless (no `/bin/sh`), and `aws ecs
execute-command` is normally used to drop into a shell. Whether `--command
"python3 /app/healthcheck.py"` (a direct binary invocation, no shell
metacharacters) works cleanly against a shell-less container via ECS Exec
is an open question this project hasn't tested live. Treat this as
infrastructure worth having enabled, not a proven workflow — the first real
use should confirm (and document here) whether a non-interactive,
shell-less exec actually behaves as expected.

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

### `drain_minutes` is overridable per dispatch

The default drain (1h staging, 24h prod) exists to prove the new slot
stable under real traffic before the old one loses capacity — but every
minute of overlap is double capacity, double cost. A manual dispatch of
`deploy.yml` (or `ci.yml` with its `deploy` box checked) can override it
with `drain_minutes` — blank keeps the environment default, `0` drains
immediately (already a supported `cleanup.yml` mode: its "Wait for delay"
step's own `if:` skips the sleep entirely on `0`, needing no changes
there).

**A plain `git push` cannot carry this** — GitHub only attaches `inputs` to
`workflow_dispatch` events; a `push` has none. `ci.yml`'s auto-triggered
deploy (the one that fires on every ordinary push) always gets an empty
`drain_minutes`, so it always uses the environment default. Overriding it
requires manually dispatching one of the two workflows above.

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

`init_db.py` creates the least-privilege `nexusapp` DB user and brings the
schema to the latest Alembic revision (`app/migrations/`, see
`#real-alembic-migrations-replace-db.create_all` below). It runs as a
standalone ECS Fargate task — the worker's task definition with its command
overridden — inside the VPC, so it reaches private RDS the same way the app
does. It is idempotent, so re-running it on every deploy is safe and
simpler than tracking whether it already ran. `continue-on-error: true`
because a failed init shouldn't block a deploy whose schema is already in
place from a prior run.

### Real Alembic migrations replace db.create_all()

`app/migrations/` didn't exist until this pass, despite Flask-Migrate being
wired into `extensions.py`/`app.py` since the beginning — `init_db.py`'s
`create_schema()` called `db.create_all()` directly instead. That's a real
functional gap, not just a missing nicety: `create_all()` only creates
tables that don't exist yet; it never issues an `ALTER TABLE` for a column
added to an existing model. Any schema change beyond a brand-new table had
no deployable upgrade path.

Generated the initial migration by pointing `flask db migrate` at the
existing models (`flask --app 'src:create_app("development")' db init` /
`db migrate -m "initial schema"`), then verified it byte-for-byte against
the models with `flask db check` (`No new upgrade operations detected.`) —
the migration is not hand-written, it's Alembic's own autogenerate output,
kept because it matched exactly. `create_schema()` now calls
`flask_migrate.upgrade()` instead: idempotent when run one at a time (a
database already at head is a no-op, same safety property `create_all()`
had), and it reuses `db.engine` directly (`migrations/env.py`'s
`get_engine()`) rather than opening a second connection — which is what
makes it safe for the in-memory SQLite `TestingConfig` uses, since both
migration and test queries share the same engine/connection. Serialized on
PostgreSQL by an advisory lock — see the concurrency note below (an earlier
version of this note claimed blue-green safety before any lock existed).

Going forward, a model change needs `flask db migrate -m "..."` to generate
the matching revision — a schema change with no corresponding file under
`app/migrations/versions/` will never reach a deployed database no matter
how correct the SQLAlchemy model looks locally (SQLite's local dev/test
paths create tables from the model directly via this same `upgrade()`
path, so the drift would only show up against real Postgres).

**Concurrent `upgrade()` calls are serialized by a Postgres advisory
lock.** `entrypoint_worker.py` runs `create_schema()` on every worker
container's own startup (not just the explicit `init_db` one-shot task), and
Alembic takes no lock of its own, so two blue-green slots (or a scaled-out
worker) restarting together could race the same DDL. An earlier draft of this
note wrongly claimed safety; a later one recorded it as an open gap.
`create_schema()` now wraps `upgrade()` in `pg_advisory_lock` /
`pg_advisory_unlock` on a dedicated connection (PostgreSQL only; SQLite has no
concurrent writers). Verified against a live Postgres: 4 concurrent callers on
an empty database all finish with no errors at head, while the same 4 with the
lock removed deadlock on DDL.

**No baseline procedure exists for a database that already has tables from
the old `db.create_all()` path but no `alembic_version` row.** `upgrade()`
from a blank revision history would try to `CREATE TABLE` on tables that
already exist and fail with a duplicate-table error — the standard fix is
`flask db stamp <revision>` to tell Alembic "the schema is already at this
revision, just record it," without touching the DB, before ever calling
`upgrade()` for real. Not built here because it's currently moot for this
project's actual state: staging is torn down and recreated on every
provision cycle (never carries forward a legacy schema), and prod has
never actually been deployed (dispatched once, cancelled at the manual
approval gate — see `CLAUDE.md`) — there is no real database anywhere
that was ever created via the old `db.create_all()` path. If that ever
changes (a real deploy target that predates this migration setup), stamp
it at `7f46ffc9b095` (this pass's initial-schema revision) before the first
`upgrade()` run against it.

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
trade-off, originally dev-only. Staging set it `true` too from 2026-09-05
onward, under [[aws-budget-constraint]] — a deliberate, asked-for exception
to otherwise mirroring prod (endpoint cross-AZ HA has little value for a
short-lived, manually-verified environment). Prod keeps it `false` (AWS
recommends ≥2 AZs for endpoint HA).

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

### Two unrelated SSM namespaces under `/nexusdeploy/<env>/`

Easy to confuse, worth keeping separate explicitly. `bootstrap.sh` owns
`{db,app,monitoring}/*` (master/app DB credentials, Flask secret/JWT keys,
the Grafana password) — Terraform only ever reads these; bootstrap
create-once-skips-if-exists, never overwrites a live secret.

`deployment/{active_slot,generation,prev_api_image,prev_worker_image}` are
entirely different: workflow-owned, not a Terraform resource at all (as
of commit `8f9d7ab` — `active_slot` used to be, with
`ignore_changes=[value]`, deliberately removed so `terraform destroy` can
never touch any of the four). `cleanup.yml` explicitly `aws ssm
delete-parameter`s all four on a successful teardown — verified working
end-to-end against live AWS (a real teardown, twice, back-to-back, both
clean). This matters if it ever regresses:
`deploy-blue-green.yml` only falls back to the `placeholder` image when
`prev_*_image` is **absent** — a stale leftover value would make a fresh
deploy seed the idle slot with a stale image instead of the documented
first-deploy path.

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

### ElastiCache in-transit encryption and AUTH

Redis moved from a bare `aws_elasticache_cluster` to a single-node
`aws_elasticache_replication_group` (`num_cache_clusters = 1`,
`automatic_failover_enabled = false` — same topology and cost as before,
still one node, no HA charge) because `transit_encryption_enabled` and
`auth_token` don't exist on `aws_elasticache_cluster` at all — the AWS
provider only exposes them on a replication group, regardless of node
count.

`REDIS_URL`/`CELERY_BROKER_URL`/`CELERY_RESULT_BACKEND` all switched from
`redis://` to `rediss://:<token>@host:port/db` accordingly. No application
code change was needed: redis-py's `Redis.from_url` (`extensions.py`),
Kombu's Celery redis transport, and `limits`' Flask-Limiter Redis backend
all already treat `rediss://` as "connect over TLS" and parse a URL
password as the `AUTH` argument — the scheme and embedded token alone
carry the whole change. `config.py`'s `redact_url()` needed no change
either — it masks whatever `urlparse` finds in `parsed.password`,
generically, regardless of scheme.

**Auth token character set — corrected after an initial wrong assumption.**
`random_password.redis_auth` first reused `SEED_ADMIN_PASSWORD`'s
`override_special = "!#$%^&*()-_=+"`, on the assumption that AWS's AUTH
token restriction was the same "avoid `/`, `"`, `@`, whitespace" denylist
Secrets Manager-style passwords typically avoid. It isn't — confirmed
directly against AWS's own ElastiCache AUTH docs: token nonalphanumerics
are restricted to an **allowlist** of exactly `!`, `&`, `#`, `$`, `^`, `<`,
`>`, `-`. The original charset included `%`, `*`, `(`, `)`, `_`, `=`, `+`,
none of which are on that list — a generated token containing any of them
would have been rejected outright by the ElastiCache API at apply time,
which only a real `terraform apply` (not `plan`) would have caught, since
`plan` doesn't validate token contents against the service. Fixed to
`override_special = "!&#$^<>-"`. Separately, `#` *is* allowed by AWS but is
a URL-fragment delimiter — a raw, unencoded `#` in the token would silently
truncate the parsed password at the wrong point. Both
`REDIS_URL`/`CELERY_BROKER_URL`/`CELERY_RESULT_BACKEND` now wrap the token
in Terraform's `urlencode()` before interpolating it.

No at-rest encryption was added alongside this. This Redis instance holds a
Celery broker/result backend, rate-limit counters, and short-TTL JWT
blocklist entries — nothing long-lived or sensitive enough at rest to
justify the (small) added complexity; transit encryption is the control
that actually matches this data's risk (credentials/tokens crossing the
network), not storage. `at_rest_encryption_enabled` cannot be changed after
creation, so this was a deliberate one-time choice, not something deferred
to "fix later" — revisiting it means recreating the replication group.

**Migrating a live, populated Redis to this design is destructive, though
moot for this project today.** `aws_elasticache_replication_group` is a
different resource type from `aws_elasticache_cluster`; Terraform has no
in-place adoption path between them, so an environment with a real,
already-provisioned standalone cluster would see this as a destroy-and-
recreate, not a conversion — losing whatever was queued in Celery, cached,
rate-limited, or blocklisted at that moment. Not an issue for *this*
project's actual current state: dev/staging/prod all have empty Terraform
state under the budget freeze (confirmed via `terraform state list`
returning nothing everywhere, and via the `terraform plan` below showing a
fresh create, not a replace), so there is no live cluster this change could
actually destroy. Would need a real migration procedure (AWS supports
creating a replication group from an existing single-node cluster) before
reusing this exact pattern against an environment that has real, populated
data.

Verified against real AWS (read-only `terraform plan`, all three
environments currently have empty state under the budget freeze, so this
plans as a fresh create everywhere) — not yet verified end-to-end with a
live apply.

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

### Self-hosted tracing: OTel Collector + Jaeger, not X-Ray

Distributed tracing runs on the existing monitoring EC2 (`terraform/modules/monitoring`)
instead of AWS X-Ray — [[aws-budget-constraint]] rules out a per-trace-billed
AWS service, and the monitoring box already exists and is already paid for.
Jaeger v2 (not the old v1 "all-in-one") is used because v2 **is** an OTel
Collector distribution with Jaeger's storage/query/UI built in — it speaks
OTLP natively, no separate collector needed. Verified locally end-to-end
before any of this was deployed (2026-09-05): a real Flask app, instrumented
exactly as shipped, sending real spans over OTLP/HTTP to a real Jaeger v2
container, queried back via its API — `GET /health` → `connect` →
`SELECT nexusdeploy` → `PING`, correctly nested.

**Config is deliberately minimal** (`files/jaeger-config.yaml`): a single
in-memory trace store (`max_traces: 2000`, bounding worst-case RAM — kept
in the low thousands rather than a 10k+ default, since large traces can
reach several hundred MB at that count and risk the OOM killer taking out
a sibling service, not just Jaeger itself; `jaeger.service`'s systemd unit
also sets `MemoryMax=256M` as a second, harder backstop), no
adaptive/remote sampling, no AI/MCP UI assistant, no pprof/zpages — every
extension is memory this t3.micro doesn't have to spare, already sharing 1GiB
with Prometheus, Grafana, node_exporter and YACE. Traces don't survive an
instance restart; that's an accepted trade for zero EBS/DB cost on a tool
whose job is live debugging, not an audit trail.

**Only OTLP/HTTP (port 4318) is exposed, not gRPC (4317)** — avoids
`grpcio`'s native C-extension in the app image, one more thing that could hit
the same builder/runtime version-skew class of bug documented in
[Distroless runtime images](#distroless-runtime-images). The Jaeger UI
(16686) is gated behind `monitoring_allowed_cidr`, the same allowlist as
Grafana/Prometheus — not open to the VPC.

**Security groups**: `api`'s existing blanket VPC-internal egress rule
already covers reaching the collector; `worker` needed a new, narrowly-scoped
egress rule since it has no such blanket rule. Originally added as a
standalone `aws_security_group_rule.worker_to_monitoring_otlp`, scoped to
`source_security_group_id = aws_security_group.monitoring[0].id` — this was
wrong: `aws_security_group.worker` already declares its egress rules
inline, and the AWS provider treats a security group's inline rule blocks
as the complete, authoritative set for that group. Mixing them with a
separate `aws_security_group_rule` for the same group means each apply
fights over which is correct, and the standalone rule can end up silently
revoked. Fixed by moving the OTLP rule inline into `aws_security_group.worker`
itself, scoped by `var.vpc_cidr` (matching this SG's other VPC-internal
egress rules) rather than the monitoring SG specifically — which also
removes the dependency on `var.monitoring_enabled` the standalone resource
needed, since the monitoring instance is inside the VPC either way. Both
directions of this traffic remain one-directional — nothing needs to reach
*into* the app tasks for this.

**A new real dependency**: each `module.ecs`/`ecs_slot1`/`ecs_slot2` call now
passes `otel_exporter_endpoint = "http://${module.monitoring.monitoring_private_ip}:4318"`,
so ECS task definitions now depend on the monitoring EC2 instance existing
first. Previously monitoring and ECS provisioned in parallel (monitoring's
`ecs_cluster_names` input is a constructed string, not a module output,
specifically to avoid the reverse dependency). This one is unavoidable in
that direction — the endpoint really does need a real IP — but it only
delays *task definition creation*, not application readiness; Terraform
doesn't wait for the EC2 instance's user_data to finish, only for the
instance to exist.

**Monitoring's user_data was refactored while this was built**: every
install step (node_exporter, Prometheus, YACE, Jaeger, Grafana, the nginx
frontend, the ECS-discovery cron script) moved out of the inline
`monitoring-userdata.sh.tpl` into standalone scripts under
`files/scripts/`, uploaded to S3 and fetched+run at boot — the same
"config lives in S3" pattern already used for `prometheus.yml` and friends,
now extended to the install logic itself. Only what genuinely can't be
S3-fetched stays inline: apt packages, the AWS CLI install (needed before
any S3 fetch can happen at all), and the Grafana password fetch from SSM.
Shared values (project/environment/region/bucket/cluster names/the Grafana
password) pass to every fetched script via one root-owned (chmod 600)
env file, `/etc/nexusdeploy-monitoring.env`, sourced at the top of each —
replacing Terraform's `$${...}`-escaped template interpolation, which only
applied to the one file actually passed through `templatefile()`. Net
effect: the orchestrator shrank from over 16KB raw to under 10KB, with room
to add more install steps later without approaching the limit again.

### `worker` and `api` gained a new health-of-observability concern

`app/src/otel.py`'s `setup_tracing()`/`instrument()` are the one thing that
runs identically in `create_app()` regardless of which of the three services
(api/worker/beat) is booting — all three already share that factory. Kept
strictly opt-in on `OTEL_EXPORTER_OTLP_ENDPOINT` being non-empty: local dev
and tests never set it, so this is a genuine no-op there, not a
network call that silently times out. SQLAlchemy instrumentation runs
*before* `db.init_app(app)` deliberately — it patches engine creation
itself, so it has to exist before Flask-SQLAlchemy creates one. Celery
instrumentation is unconditional across all three services rather than
worker/beat-only: producer-side spans on `api` are what let a trace started
by an HTTP request continue into whichever worker later processes the task
it enqueued.

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

### Rate-limiter storage diagnostic — closed, kept as a regression guard

`create_app` logs `Rate limiter storage: uri=<redacted> backend=<class>`
right after `limiter.init_app`, added to answer a question ECS Exec being
disabled otherwise blocks: staging containers once logged flask-limiter's
"using the in-memory storage" warning even though `RATELIMIT_STORAGE_URI`
resolved to a real Redis URL — a case a local repro of
`create_app("production")` never reproduced. In-memory storage means
limits are per-Gunicorn-worker and reset on restart, so the documented
global limit would silently not be in force. **Resolved**: a redeploy
logged `backend=RedisStorage` cleanly in both api and worker containers
with no warning, and it hasn't recurred. The diagnostic line stays in
place as a standing regression guard — re-open the investigation only if
`backend=unset`/the in-memory warning shows up again, and get
`RATELIMIT_STORAGE_URI`'s actual runtime value from the container at that
point (ECS Exec being disabled is what made this hard to debug directly
the first time).

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

### Coverage omit list is a reachability boundary, not gaming

`run.py`/`wsgi.py`/`celery_worker.py` are omitted from `--cov=src`
(`pyproject.toml`'s `[tool.coverage.run]`) because each only calls
`create_app()` (or, for `celery_worker.py`, also `app.app_context().push()`)
with no branchable logic of its own — `create_app()` itself stays fully
measured via every other test in the suite. This is the internal tier of a
tiered-reachability policy: waivable in bulk because it's exercised
transitively through an already-covered caller, not because it's untested
in principle. `cache_service.py`/`s3_service.py`, despite having zero real
callers in `src/` today (only `src/services/__init__.py`'s own re-export
references them — pre-emptive coverage, not a sign they're wired in), are
**not** on this list — they carry real branching/error-handling logic of
their own and are covered directly (`tests/test_cache_service.py`/
`tests/test_s3_service.py`).

Real coverage with the omit list applied is 90% (`cd app && pytest tests/
--cov=src --cov-report=term-missing`), well above `ci.yml`'s
`--cov-fail-under=85` — a regression backstop with real margin, not a
number chased for its own sake. The previous floor (`60`) had drifted 10+
points stale below actual coverage before this pass, exactly the
percentage-target failure mode a tiered/reachability-based gate avoids.

A real "test at the wrong seam" trap surfaced while writing
`test_cache_service.py`: `cache_service.py` does a *module-level*
`from ..extensions import redis_client`, binding its own private copy of
whatever `src.extensions.redis_client` was at `cache_service`'s own import
time (`None`, since nothing imports `src.services` before a test does).
`init_extensions` reassigns `src.extensions.redis_client` later via
`global redis_client` — reassigning the *module attribute* never touches
`cache_service`'s already-bound copy. `patch("src.extensions.redis_client",
...)` — the pattern `tests/test_health.py` uses successfully, because
`app.py`'s health check re-imports `redis_client` *inside* the function
body on every call — silently does nothing here: a sloppy assertion can
still "pass," but only because the mock was never actually consulted.
Every `cache_service` test patches `src.services.cache_service.redis_client`
instead; verified by deliberately patching the wrong target first and
confirming the test passes for the wrong reason before locking in the
right one.

**Mutation testing** (ad hoc, not CI — per the cross-project engineering
resources' guidance to scope it small and run it by hand): `init_db.py`'s
fail-closed seeding guard above is the single highest-value target found —
a silently weakened check there means a real deployment seeds default
credentials. Not added to `app/requirements.txt` (that file ships in the
production Docker images; a mutation tool has no business there). Run
inside a disposable container (mutmut's classic engine mutates the target
file in place, then reverts it — never point it at a bind-mounted working
tree, only a container-internal copy):

```bash
pip install mutmut==2.4.5   # matches the --paths-to-mutate/--runner CLI below;
                             # mutmut 3.x replaced these with a pyproject.toml config
cd app && mutmut run --paths-to-mutate=src/init_db.py --runner="pytest tests/test_init_db.py"
mutmut results   # review survivors by hand
```

**Run 2026-09-19, 179 mutants generated, 12 killed, 2 survived, 165
untested/skipped** (mutants outside the lines `test_init_db.py` actually
exercises — expected for a file-scoped run against one test file). The two
survivors:

- A string-literal mutation of the `DATABASE_URL` missing-env-var error
  message — benign. No test asserts the exact message text, only that
  `RuntimeError` is raised; the behavior itself is unchanged.
- **A real gap, fixed**: `_get_master_conn`'s guard
  `if not master_user or not master_password` survived being mutated to
  `and`. The existing test only covered "both credentials missing" — a
  partial pair (one of `DB_MASTER_USER`/`DB_MASTER_PASSWORD` set, the other
  absent) would silently pass the guard under the mutant and proceed with a
  `None` value. Added
  `test_get_master_conn_raises_with_only_one_master_credential_set`
  (`app/tests/test_init_db.py`), plant-confirmed red against the mutant,
  green against the real `or`.

### Celery Beat is a singleton

Beat always runs at `desired_count = 1`. Two Beat instances fire every scheduled
task twice.

This holds across a blue-green overlap too, but not via the same apply that
stands up the candidate slot. `beat_slot`
(`terraform/environments/{staging,prod}/main.tf`) decouples Beat's cutover
from `deployment_slot`: the candidate-creation apply holds Beat on the OLD
slot, and only a second, narrow apply — gated on the same
`steps.gate.outputs.promote` condition as `active_slot`, see
#promotion-order — cuts it to the new slot, in `deploy-blue-green.yml`. A
slot that fails its health check, or (staging) its `init_db` run, never runs
Beat at all. On a first-ever deploy `beat_slot` is left unset and defaults to
`active_slot`, so Beat starts with everything else in that single apply —
there's no previous slot to hold it back from.

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

**`ci.yml`'s `workflow-lint` job now catches this class of bug
automatically** — greps every workflow file for `vars.`/`secrets.`/
`needs.*.outputs.*` interpolated directly inside an `echo "..."` string and
fails the build if found. Runs unconditionally (no path gating), so it
catches a workflow-only edit too. `github.event.inputs.X` is deliberately
exempt — a `workflow_dispatch` choice input's value space is a fixed enum,
so it cannot carry a stray `"`. If a real future value legitimately needs
this pattern, route it through `env:` first rather than adding an
exception to the grep.

**Meta-note on writing this very fix:** don't put a literal `${{ }}` — even
empty, even inside a `#` comment — anywhere in a workflow YAML file. A
`run: |` block scalar has no bash-level comments from YAML's perspective;
GitHub scans the whole resulting string for expressions before bash ever
sees it, so `${{ }}` there is a real (if empty and invalid) expression
attempt, not inert text. Describe the mechanism in words instead (as this
section does) — `.md` files like this one are never parsed by GitHub
Actions, so the literal syntax is safe to show here.

### Per-slot Celery queues close the worker version-skew gap

RDS and ElastiCache are declared once per environment, not once per slot
(`terraform/modules/rds`, `terraform/modules/elasticache`, both wired into
both `ecs_slot1`/`ecs_slot2` via the same `depends_on` and the same
Secrets Manager secret) — so both slots' workers share one Postgres and one
Redis. `keep_previous_slot_running` correctly keeps the old slot's worker up
throughout the candidate's health check *and* the whole drain window (1h
staging, up to 24h prod, see #the-old-slot-stays-at-capacity-through-the-apply)
— by design, so the old slot keeps serving while the new one proves itself.
This used to mean an old-version and new-version worker consumed from the
*same* implicit default Celery queue for the entire overlap — a real
version-skew risk if a task's payload shape ever changed between the two
versions.

Fixed via a per-slot queue name, not shared routing logic: `var.environment`
already carries the slot suffix in blue-green environments
("staging-slot1"/"staging-slot2" — #container-env-strips-the-slot-suffix-and-forces-debug-off),
so `terraform/modules/ecs/main.tf`'s `app_environment` sets
`CELERY_TASK_QUEUE = "tasks-${var.environment}"` per slot, and
`extensions.py::init_celery()` sets `task_default_queue` from it. Every
`.delay()` call site (`create_task`, `update_task`, `create_comment`)
needed zero changes: none of them pass `queue=`, so they all route through
`task_default_queue` automatically — and a Celery worker started with no
`-Q` flag (this project's worker/beat commands never pass one) consumes
exactly that same default queue. The earlier plan called producer-side
routing to "whichever queue the currently active slot reads" nontrivial,
because a producer can't know which slot is "current" at enqueue time —
that framing turned out to be the wrong question. The right invariant isn't
"route to the active slot," it's "route to your own slot": each slot's API
enqueues to its own queue, and that same slot's worker is the only thing
that ever reads it, so an old-version producer's task is always handled by
an old-version worker, and a mismatched payload shape between versions
never occurs, regardless of which slot happens to be "active" in SSM at any
given moment. `dev` has no blue-green concept at all, so it gets a fixed
`tasks-dev` queue — harmless, since there's nothing to isolate it from.

Per-slot isolation raised a **new** risk symmetric with the old one: since
a slot's queue now has exactly one consumer, reclaiming that slot's
capacity while its queue still holds tasks orphans them forever — nothing
else will ever read that queue. `cleanup.yml`'s drain-reclaim job gained a
`Check old slot's Celery queue is drained` step before the reclaim apply:
`app/src/queue_depth_check.py` runs as a `run-task` override on the old
slot's own worker task definition (its own `REDIS_URL` secret and
`CELERY_TASK_QUEUE` env var are already exactly right, so the override
needs no extra environment, only the command). `LLEN <queue-name>` is
checked first — verified empirically against a real local Redis that
Kombu's redis transport stores a queue as a plain Redis list keyed by the
queue name, with no vhost/exchange prefixing to account for here — but
**LLEN alone is not sufficient**: this project's Celery config never sets
`task_acks_late`, so the default (early ack) removes a message from Redis
the moment a worker's prefetch buffer takes it, before the task body has
actually finished running. A worker mid-execution, or holding a prefetched
task, would read as "queue empty" on LLEN alone. The check also calls
`celery.control.inspect().active()`/`.reserved()` and requires zero tasks
whose `delivery_info.routing_key` matches the queue — verified against a
real local Celery worker (prefork-equivalent; `--pool=solo` specifically
does *not* work for this verification, since a solo worker blocked
executing a task can't answer the control-plane inspect call either — this
project's real workers use `--concurrency=2`, prefork, where the mother
process stays responsive). If no worker replies to the inspect call at
all — a real possibility if the old slot's worker has already died for
some unrelated reason — that's treated as "cannot verify," not "nothing in
flight," and blocks the reclaim rather than guessing. Polls every 20s for
up to 300s before refusing to reclaim; a queue still non-empty (by either
check) after that leaves the old slot at capacity (billed, but nothing
orphaned) rather than silently losing tasks, and surfaces as `⏸️ Blue-Green
Drain BLOCKED` in the job summary, distinct from a guard-abort or a failed
apply.

**A real bootstrapping gap, accepted rather than engineered around**: the
very first blue-green rotation after this feature ships will have an old
slot running an image from *before* `queue_depth_check.py` existed — the
`run-task` override would fail outright (module not found), and the
fail-closed design means that reads as "cannot confirm drained," blocking
that one reclaim. This is a one-time transition cost, not a recurring
bug — every rotation after the first has an old slot whose image already
contains the module. Not engineered around (e.g. by special-casing a
missing-module failure as "assume drained") because that would weaken the
fail-closed guarantee for a saving of exactly one manual intervention,
ever, in this project's history. If it happens: confirm manually that the
old slot's queue is actually empty (`redis-cli LLEN <queue>` via ECS Exec
or a one-off task on the *new* image), then re-run the drain dispatch —
the guard step re-validates the generation before proceeding, so this is
safe to retry.

Not yet verified against real AWS — the elasticache TLS/AUTH change above
already established that dev/staging/prod all currently have empty state
under the budget freeze, so this needs a real deploy (and, to actually
exercise the queue-depth gate meaningfully, a registered periodic or
manually-triggered task — today's tasks are all fired from user requests,
so there is nothing to genuinely test the "queue still has items" branch
with beyond deliberately holding a task in flight).

### Celery task idempotency is deferred, not designed in yet

`create_task`, `update_task`, and `create_comment` dispatch
`send_task_assignment_email.delay(...)`/`send_comment_notification.delay(...)`
with no idempotency key, and Celery's broker guarantees at-least-once
delivery — a broker-level redelivery (worker crash mid-task, visibility
timeout, restart during a blue-green drain) can run the same task twice.

Deliberately not fixed today: every task in `app/src/tasks/email_tasks.py`
is currently log-only (see
`#rate-limiter-storage-diagnostic--closed-kept-as-a-regression-guard`'s
neighbor section on the email stubs below) — a duplicate run produces one
extra log line, not a duplicate real-world side effect. That safety margin
is temporary, not structural: the moment a real email provider is wired in,
the same duplicate-delivery path becomes a real duplicate-send risk with no
code change needed to trigger it, since the `.delay()` call sites don't
change, only what's inside the task. Tracked here explicitly so wiring in a
provider without also adding an idempotency key (e.g. a dedupe key derived
from `(task_id, assignee_id)` or `(comment_id, user_id)`, checked via
`CacheService`/a dedicated Redis set before sending) is a visible regression
against a documented decision, not a silent gap.

### Email tasks are stubs, not a wired-up provider

`app/src/tasks/email_tasks.py`'s three tasks only log — no SMTP/SES/SendGrid
call exists anywhere in `src/`. Log lines and return values are worded
`[EMAIL-STUB]`/`[DIGEST-STUB]`/"logged" rather than "sent", deliberately: a
return value or log grep that says "sent" is a plausible-wrong-answer risk
the moment anything downstream (a test, a dashboard, an on-call runbook)
treats it as delivery evidence. Wiring in a real provider should update
this wording at the same time, not leave "sent" retroactively true only by
coincidence of timing.

### Deliberately deferred: fuzz/property-based testing on `validation.py`'s parsers

`utils/validation.py`'s `parse_datetime`/`parse_int` are covered by
example-based unit tests (malformed strings, boundary values, the
`bool`-is-an-`int`-subclass trap) but not by property-based/fuzz testing
(e.g. Hypothesis). This is a real gap against
`coding-standards.md`/`engineering-practices.md` §30's risk-based testing
guidance, not an oversight — recorded explicitly rather than left
unstated. Reasoning: both parsers are pure, small, and fail closed today
(a parse failure raises `ValidationError`, caught and turned into a 400 —
never silently coerced into a wrong-but-plausible value), so the blast
radius of an untested edge case is a validation-error response, not
corrupted data or an auth bypass. Revisit if either parser's fail-closed
behavior ever changes, or if a caller starts trusting a parsed value
without the current error handling around it.

### The coverage omit list's tier is self-declared, not derived from a call graph

`engineering-practices.md` §8 asks for a covered/omitted split "derived
from the actual call graph," but `pyproject.toml`'s `[tool.coverage.run]`
omit list (`run.py`/`wsgi.py`/`celery_worker.py`) is a hand-maintained list
with a stated rationale (see
`#coverage-omit-list-is-a-reachability-boundary` above), not the output of
call-graph tooling. Deliberate, not an oversight: this is a small,
single-package Flask app where the omitted files' full call graph (three
files, each just calling the already-exhaustively-tested `create_app()`)
is verifiable by reading them, and the tooling investment to derive it
mechanically (e.g. a coverage-aware static analyzer wired into CI) isn't
justified at this codebase's size. Revisit if the omit list ever grows
past a handful of genuinely-trivial entry points, where "verifiable by
reading them" stops being a credible substitute for real tooling.
