---
name: sync-firstmate
description: >-
  Run the upstream-to-private firstmate sync workflow end to end: measure how far kunchenguid/firstmate has drifted ahead of the private copy, dispatch a direct-PR ship that merges it in as a coherent union, and after the captain's explicit confirmation merge the PR and update this home.
  User-invoked only through /sync-firstmate; the model must never auto-trigger it.
disable-model-invocation: true
user-invocable: true
metadata:
  internal: true
---

# sync-firstmate

This workflow keeps `tomastoth4/firstmate-private` current with `kunchenguid/firstmate` without ever pushing to or merging against the upstream fork.
Firstmate never edits `projects/firstmate` directly (hard rule 1); every step below either reads that clone or dispatches a worker to change it.

## 1. Measure drift

1. `git -C projects/firstmate fetch origin` and `git -C projects/firstmate fetch private`.
2. Count new upstream commits: `git -C projects/firstmate log --oneline private/main..origin/main | wc -l`.
3. If the count is zero, tell the captain the private copy is already in sync with upstream and stop here.

## 2. Dispatch the merge ship

1. Choose a task id `fm-upstream-merge-<MMDD>` for today's date; the default `fm/` branch prefix then yields ship branch `fm/fm-upstream-merge-<MMDD>`.
2. Scaffold with `bin/fm-brief.sh <task-id> firstmate --mode direct-PR` (AGENTS.md section 7 owns mode and intake authority; this workflow is always direct-PR into the private fork, never `no-mistakes` and never a PR against `kunchenguid`).
3. Fill `## Captain's intent` with the ask: merge the firstmate changes from `origin` (`kunchenguid/firstmate`) into the private copy (`tomastoth4/firstmate-private`) on top of the private customizations, so they can be reviewed and merged in.
4. Fill `## Firstmate spec` with these build instructions:
   - Load `firstmate-coding-guidelines` first; this is firstmate's own core, so correctness wins over speed.
   - Branch `<task-id>` from `private/main`, with one merge commit of `origin/main`.
   - Resolve every conflict as a coherent union: keep every upstream feature and every private customization.
   - List the private-only commits with `git log --no-merges private/main ^origin/main` and confirm each one's behavior still holds after the merge.
   - Where upstream reimplemented a private feature, keep one implementation, prefer upstream's, and confirm the private behavior still holds.
   - Confirm `config/brief-include.md` support in `bin/fm-brief.sh` still works: scaffold a throwaway brief in a temp `FM_HOME` with a brief-include file present and check the rendered `# Home brief additions` section.
   - Require no conflict markers, `bash -n` on every changed `bin/*.sh`, ShellCheck where available, and passing colocated tests for every touched area; report exactly what ran and what could not.
   - Push the branch to `private` and open exactly one PR into `tomastoth4/firstmate-private` main, never against `kunchenguid`, using the repo PR template if one exists; the body states the upstream range merged, the private features preserved, the conflicts that needed judgment, and a verified vs not-verified list.
   - Out of scope: any other feature change, refactor, or cleanup; no agent co-author; no direct address or private notes in commits, code, or the PR.
5. Resolve the dispatch profile per section 4 and spawn through `bin/fm-spawn.sh` like any other ship task.

## 3. When the PR is ready

Give the captain the PR's full URL, the exact upstream commit range merged, and the conflicts the worker flagged as needing judgment.
Ask for explicit confirmation to merge and relaunch; hard rule 2 forbids merging without it.

## 4. After the captain confirms

1. Merge with `bin/fm-pr-merge.sh`, never a lower-level merge command.
2. Run the `/updatefirstmate` skill to fast-forward this home to the merged commit and restart the main session and every live secondmate.
