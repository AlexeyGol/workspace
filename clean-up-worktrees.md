# clean-up-worktrees.sh

Audit and remove git worktrees across the workspace.

Worktrees accumulate, and they scatter. In this workspace they turn up in at
least three places:

```
worktrees/<repo>-<ticket>-<recap>/                 # the convention
sources/<host>/<repo>-<ticket>-<recap>/            # created next to the repo by mistake
sources/<host>/<repo>/.claude/worktrees/<name>/    # created by a Claude Code session
```

Because a worktree belongs to one repo, `git worktree list` only ever shows you
the ones for the repo you happen to be standing in. This script asks every repo
under `sources/`, so one run shows the whole workspace.

## Usage

```bash
./clean-up-worktrees.sh              # audit only — changes nothing
./clean-up-worktrees.sh --yes        # remove every SAFE worktree, no prompts
./clean-up-worktrees.sh -i           # prompt y/N per SAFE worktree
./clean-up-worktrees.sh 17285        # narrow to worktrees matching a filter
./clean-up-worktrees.sh -y 17285     # combine
./clean-up-worktrees.sh --help
```

The filter is a substring, matched against both the worktree path and the branch
name — a ticket number is usually the handiest form.

Run it with no arguments first. The audit is read-only and is the point of the
script; removal is the afterthought.

### Which flag to use where

`--interactive` needs a terminal to prompt on. **Claude Code's `!` shell has no
tty**, so a prompt there can never be answered and nothing is removed — the
script says so rather than reporting a silent "skipped". Use `--yes` from Claude
Code, or `--interactive` from Git Bash directly.

## Status meanings

| Status | Meaning | Removed? |
|---|---|---|
| ✅ `SAFE` | on origin at the same SHA, behind origin, or fully merged into the repo's default branch | yes, on `y` or `--yes` |
| 🛑 `RISK` | uncommitted changes, detached HEAD, or commits that exist nowhere but here | **never** |
| 🔒 `LOCKED` | `git worktree lock`-ed — typically a live Claude Code session | **never** |
| ❓ `UNKNOWN` | origin could not be reached, so safety is undecidable | **never** |
| 🧹 `PRUNE` | directory already gone, only stale metadata remains | metadata pruned |

A `⚠ not under worktrees/` note marks worktrees that violate the workspace
naming convention. It is informational and never affects removal.

## What removal does, and does not, do

Removing a worktree deletes **its working directory only**. The branch is always
kept, so anything removed here comes back with:

```bash
git -C sources/<host>/<repo> worktree add \
    worktrees/<repo>-<ticket>-<recap> <branch>
```

No `-b` and no `--no-track` here — the branch already exists, and `--no-track`
is rejected outright unless a new branch is being created. `--no-track` belongs
on the *initial* `worktree add -b <ticket>` instead, where it stops the new
branch adopting the default branch as its upstream.

There is deliberately **no `--force`**. If the script reports `RISK`, the answer
is to push the work or look at it, not to override the check. To discard
genuinely dead work, do it explicitly and visibly:

```bash
git -C <repo> worktree remove --force <path>
git -C <repo> branch -D <branch>
```

## Why the safety check is not just `git worktree remove`

`git worktree remove` refuses to remove a worktree with uncommitted or untracked
files. It does **not** care whether the branch has commits that exist only
there — a clean worktree holding the sole copy of a commit is removed without
complaint. Closing that gap is the reason this script exists.

The check itself has one subtlety worth knowing, because the obvious
implementation is wrong. A local `refs/remotes/origin/<branch>` ref is **not**
evidence that the branch is still on the remote: the ref survives the branch
being deleted upstream. Trusting it reports orphaned commits as "pushed" — and
this workspace already contained exactly that case. So the script queries the
remote with `git ls-remote` instead, and treats a *failed* query as `UNKNOWN`
rather than as "branch absent".

That is the general shape of the rule: **"could not determine" is a third state,
never a synonym for "no".** Missing evidence fails loudly; stale evidence fails
silently and confidently, which is worse.

## Notes

- Needs network access, one `ls-remote` per worktree branch. Offline, everything
  lands in `UNKNOWN` and nothing is offered — the safe default.
- The default branch is resolved per repo, never assumed. It is genuinely mixed
  here: `master` in `edp-tekton`, `edp-install` and the older `edp-*` operators;
  `main` in `krci-portal`, `cli`, `gitfusion`, the `tekton-*` operators and the
  docs/tools repos — including `edp-cluster-add-ons`, despite the `edp-` prefix.
- Repos are discovered by the same mechanism `git-pull-all.sh` uses — `.git`
  **directories** under `sources/`, here to a depth of 5 rather than 4 to leave
  room for deeper nesting. A worktree's `.git` is a *file*, not a directory, so
  worktrees are never mistaken for repos.

## Related

- `bootstrap.sh` — clone components into `sources/`
- `git-pull-all.sh` — fast-forward every repo in `sources/`
