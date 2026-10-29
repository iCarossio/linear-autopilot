# Fan-out QA (big failure lists)

When a QA or parity run leaves many failures across suites, don't send the whole list to one implementer (it times out or fixes one class and drops the rest):

1. One implementer merges and runs the suites only (no triage), and reports per-suite counts and report paths.
2. Split the failures into scopes of a size one model can read in one run: one suite, or one slice of a big suite (by page group or viewport). Run one read-only diagnoser per scope in parallel: `SCOPE="..." SCOPE_ID=<slug> WT=<wt> bin/mkbrief diag <ISSUE> 0 <ticket.md>`, then `bin/run-model run review <brief> .autopilot/out/<ISSUE>-diag-<slug>.json --cwd <wt> --prefer <key>`. Alternate cheap models across vendors. 4 to 20 diagnosers depending on the number of scopes; they are read-only, so container limits don't apply (the server they read from must already be running).
3. Merge the JSON reports into one todo list deduplicated by root cause (`.autopilot/out/<ISSUE>-todo.md`): a cause found by two scopes is one item. Reject shortcut fixes there.
4. Each item of size M or L, or each group of S items touching the same files, becomes a Linear sub-ticket (same milestone, `blocks` the parent) with a ticket file, dispatched through the normal loop in parallel worktrees. Items of kind `human` go to the open human decisions; items of kind `data` become reviewed exception entries.
5. Re-run the full QA on the project branch after the sub-tickets land.

Running suites in parallel yourself: build once, and make sure no wrapper rebuilds. Two wrappers rebuilding the same `dist/` while a third serves it corrupts it and every result of that run is void. Give each suite its own port, container name and checkout: suites in one worktree share generated files and overwrite each other's port. In one worktree, run serving suites one at a time.
