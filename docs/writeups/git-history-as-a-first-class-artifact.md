# Git History as a First-Class Artifact

*A case study from Ephemeral Deploy, a project management API deployed
end-to-end on AWS via a production-pattern blue-green CI/CD pipeline. This
piece is about one narrow slice of that project: what happened when a
routine merge-strategy choice quietly destroyed history, and the discipline
that grew out of fixing it.*

## The incident

`main`'s branch protection rules were originally configured to squash-merge
every pull request into a single commit. This is a common default, and for
a while it looked harmless — cleaner history, one commit per feature.

It broke in a way that's easy to miss until it actually happens to you.
GitHub's squash merge concatenates the *body* of every commit on the branch
into the resulting merge commit's message. Two pull requests (#30 and #33)
had an intermediate commit whose message happened to contain the tag
`[skip ci]` — a legitimate, deliberate marker used elsewhere in the repo to
suppress a specific CI run. Squashed in, that tag silently suppressed CI —
and with it, the production deploy — for the *entire* merged PR, with no
error, no warning, and no obviously wrong signal in the GitHub UI. The merge
looked green. Nothing had actually run.

The second-order damage was worse than the first-order bug. Squash merging
also collapsed 58 individual commits across five substantive pull requests
(#13, #23, #24, #30, #33) into five squash commits on `main`. The
information about *what actually happened* during development — the false
starts, the incremental fixes, the order in which bugs were found and
patched — was gone from `main`'s history, permanently, the moment those PRs
merged. And because squash merges don't preserve ancestry the way real
merges do, `git merge-base --is-ancestor` started reporting branch commits
as *absent* from `main` even when their content had already shipped — a
genuine "did we lose this work or not?" moment that cost real debugging
time to resolve.

## What actually fixed it

The tempting fix is procedural: tell people to be careful with commit
messages. That doesn't scale and doesn't survive the next new contributor.
The actual fix was structural, in two parts.

**First, the merge strategy changed.** `main`'s ruleset now requires real
merge commits; squash is reserved for Dependabot PRs, where there's no
development history worth preserving in the first place. A merge commit's
body is the PR title only — nothing from the constituent commits leaks into
it, so the `[skip ci]` failure mode is now structurally impossible, not
just discouraged. Repo-level squash settings (`PR_TITLE`/`PR_BODY`) are a
second, redundant layer of the same protection.

**Second, the history that squashing had already destroyed got rebuilt.**
This is the part worth walking through, because it's a neat piece of git
mechanics that most engineers never need: how do you recover commits that
were never lost from the object database (they're still reachable from the
original PR branch refs) but are simply not part of any branch anyone looks
at?

```bash
git fetch origin '+refs/pull/*/head:refs/remotes/pr/*'
TREE=$(git rev-parse origin/main^{tree})
COMMIT=$(git commit-tree "$TREE" \
  -p origin/main \
  -p refs/remotes/pr/13 \
  -p refs/remotes/pr/23 \
  -p refs/remotes/pr/24 \
  -p refs/remotes/pr/30 \
  -p refs/remotes/pr/33 \
  -m "archive: preserve pre-squash history")
git branch -f archive "$COMMIT"
```

`git commit-tree` builds a commit object directly, without touching the
working tree or performing an actual merge. Given `main`'s current tree and
a list of parents, it produces a commit whose **content is byte-identical
to `main`** — nothing changes, nothing conflicts, because no merge
algorithm ever runs — but whose **parent list** includes both `main` and
every one of the five original PR heads. Git's history is a DAG of parent
pointers; content and history are genuinely separable, and this is what
that separability buys you. The result, `archive`, is a branch that looks
identical to `main` in every diff but, walked with `git log`, exposes all
58 original commits as real ancestors again. `git merge-base
--is-ancestor` works correctly against it. `git blame` on `archive` shows
the actual author and date of each original change, not a squash commit's
synthetic timestamp.

Two details matter for anyone reproducing this pattern:

- **Order the parents deliberately.** `main` has to be the first parent.
  Git conventionally treats the first parent as the "mainline," and tools
  that walk `--first-parent` history need `main`'s own commits to be it.
- **Don't over-include.** This repository also has 26 Dependabot PRs that
  were correctly squash-merged (no development history worth preserving
  there). Adding *their* PR heads as parents would have pulled in their
  pre-squash commits too, needlessly expanding a branch that's supposed to
  be a surgical fix for five specific PRs, not a wholesale history replay.

`archive` is never rebased, never merged, and never opened as a PR — its
only job is to exist as a queryable historical record. GitHub reports it as
"59 commits ahead of main," which is cosmetic (it really is one commit
ahead — the synthetic one — with a longer parent chain behind it) and
harmless to ignore.

## The discipline that came out of it

The specific bug is fixed. The more durable outcome was a standing project
rule: **history is not incidental output, it's a design artifact**, and it
gets protected with the same seriousness as the code it describes. Two
concrete practices came directly out of this incident and have stayed in
place since:

**Every non-obvious decision gets a permanent, cross-referenced record.**
This repository keeps a single `docs/design-decisions.md` file — not a
wiki, not scattered PR descriptions, one file — that states *why* something
is shaped the way it is, with inline code comments linking back to specific
anchors (`# See docs/design-decisions.md#anchor-slug`). The rule that makes
this work in practice, not just in principle: before writing a new
explanation, check whether an anchor for it already exists. A comment that
re-explains something already documented is worse than no comment — it's a
second copy of the truth that can drift from the first.

This isn't a theoretical nicety. The same project has independently found
and fixed real, previously-shipped production bugs *because* this file
existed to check against — a stale `ignore_changes = [task_definition]`
from the repo's first Terraform commit that silently prevented ECS services
from ever picking up new deployments; a CI terraform-plan step whose exit
code was being swallowed by an unguarded pipe; a health check that
verified container health but not which task definition was actually
running, which let ECS's own circuit-breaker rollback go undetected as a
false-positive "successful" promotion. Each of those got a dated,
narrated entry, not just a fix — because the *next* engineer (or the same
one, six months later) needs the "why did we do it this way" as much as
the "what does it do."

**A destructive git operation gets treated as a design problem, not a
cleanup task.** The instinct when squash history goes missing is to shrug
and move on — the code still works, after all. The instinct that actually
serves a codebase's long-term legibility is closer to what this project
did: treat the loss as a bug with a real fix, verify the fix mechanically
(`archive`'s tree really is identical to `main`'s, its ancestry really is
walkable), and write down *why* the fix works the way it does so nobody
"cleans it up" later by rewriting `main` and orphaning the artifact-to-
commit link this whole pipeline depends on (deployed ECR image tags are
literal commit SHAs — rewriting history here doesn't just lose commits, it
breaks the traceability the CI/CD pipeline exists to provide).

## Why this is worth doing on a small project

It's easy to dismiss this kind of discipline as something that only
matters at scale, with a large team, on a codebase that will outlive its
original authors by years. The counterargument is that the habit is what's
valuable, not the scale it's practiced at — and a small, single-maintainer
project is actually the *cheapest* place to build the habit, because the
cost of getting it wrong is a lost afternoon rather than a lost quarter.
The `archive` branch and the `design-decisions.md` file cost, together,
about the time it takes to write a good commit message — and they've
already paid for themselves several times over, in bugs caught during
`design-decisions.md` cross-checks that would otherwise have been
re-litigated from scratch, and in a `git blame` that still tells the truth
about who changed what and why, five squash-incidents-worth of history
later.
