# Archon 0.10.1 cutover runbook

Branches under review:
- **archon** `upstream-sync-0.10` (worktree: `/mnt/ext-fast/archon-playground/archon-upstream-sync`) — fork merged with upstream v0.10.1, all factory customizations carried.
- **interstellarai.net** `archon-0.10-cutover` (this branch) — cron-script changes.

**Recommendation: two-stage cutover.** Stage 1 (below) swaps the engine to 0.10.1 while every cron keeps invoking the same workflows — legacy workflows remain runnable by their old names (deprecation notice on stderr only), explicit `model:` pins are still honored, and every cron flag in use survives. Stage 2 (sdlc adoption) is a separate, deliberate project because the sdlc delivery tail uses durable `wait:` nodes that require a resident `archon serve` process to resume — a CLI-only cron run parks at `status: paused` forever (the CLI even exits 0). Do not big-bang.

---

## Stage 1 — switch the engine, keep the workflows

### 0. Pre-flight (any time, crons still live)
- Review both branches.
- Confirm current state: `cd /mnt/ext-fast/archon && git log --oneline -1` (expect `d3b1dba1`, branch `fix/add-archon-triage-issue-workflow`, 16 dirty entries).

### 1. Pause the factory
```bash
crontab -l > ~/crontab.backup.$(date +%F)
crontab -e   # comment out: issue-pickup, pr-review, pr-maintenance, pipeline-health, sweep-audits
# wait for in-flight runs to finish:
watch -n30 'pgrep -fa "archon workflow run" || echo IDLE'
```

### 2. Swap the main checkout
```bash
cd /mnt/ext-fast/archon
git stash push -m "pre-0.10-cutover backup of uncommitted mods"   # rollback copy; branch has them as commits
git checkout upstream-sync-0.10
bun install
CLAUDECODE=0 archon version          # expect: Archon CLI v0.10.1
```

### 3. One-time model-tier config (writes ~/.archon/config.yaml — do it now, not before)
Built-in claude tiers are small=haiku, medium=sonnet, large=opus. Only `large` deviates from the factory strategy:
```bash
CLAUDECODE=0 archon ai tier set large claude "claude-opus-5[1m]" --scope install
CLAUDECODE=0 archon ai tier list     # verify
```
This makes every legacy `model: large` reference resolve to claude-opus-5[1m]. Explicit pins (claude-opus-5[1m], claude-fable-5[1m], haiku, sonnet) in the fork-owned workflows are unaffected — 0.10.1 passes literal model strings through untouched.

### 4. Land the cron branch
```bash
cd /mnt/ext-fast/interstellarai.net
git stash push -m "pre-cutover"      # if anything uncommitted remains
git merge archon-0.10-cutover        # or: git checkout archon-0.10-cutover
```
(Crontab paths do not change; no crontab edits needed beyond un-pausing.)

### 5. Verify before resuming
```bash
cd /mnt/ext-fast/archon
CLAUDECODE=0 archon validate workflows | tail -3        # expect 78 valid / 1 error (pre-existing ntfy mcp in smart-pr-review)
CLAUDECODE=0 archon workflow list | grep -c archon-     # workflows discovered
CLAUDECODE=0 archon workflow test sdlc                  # 44 fixtures, offline
# optional per-workflow dry-runs (no provider contact):
CLAUDECODE=0 archon workflow run archon-triage-issue --dry-run --default-stubs "triage #1"
```

### 6. Resume and watch the first ticks
- Uncomment the crontab lines.
- Watch `/tmp/issue-pickup.log`, `/tmp/pr-maintenance.log`, `~/.archon/logs/sweep/`, ntfy.
- **Expected new noise:** `⚠️ archon-fix-github-issue is deprecated…` (also smart-pr-review, architect) on stderr of every legacy run — harmless, logs only.
- **Expected new behavior:** pipeline-health's zombie cleanup (`archon workflow abandon`) now actually works (it was a silent no-op on 0.3.6). On its first tick it may abandon genuinely stale `running` rows >4h old — that is the intended behavior finally activating.

### Rollback (any point)
```bash
crontab -e                                            # pause again
cd /mnt/ext-fast/archon
git checkout fix/add-archon-triage-issue-workflow      # back to d3b1dba1
git stash pop                                          # restore the uncommitted-mods state
bun install
CLAUDECODE=0 archon ai tier unset large --scope install
cd /mnt/ext-fast/interstellarai.net && git checkout <previous-branch>   # cron scripts back
crontab -e                                             # resume
```
Residual risk: 0.10 may have added tables/columns to `~/.archon/archon.db`. Upstream's schema policy is additive-only and explicitly supports older binaries opening the same DB. Belt-and-braces: `cp ~/.archon/archon.db ~/.archon/archon.db.pre-0.10` during the pause in step 1.

### Behavior differences to expect after Stage 1
| Area | Change |
|---|---|
| Legacy workflow runs | Deprecation notice on stderr each run; behavior otherwise unchanged |
| archon-fix-github-issue | Front end restructured upstream: `parse-request` (haiku-tier command, structured output) replaces the fork's `extract-issue-number` prompt node. PR is created draft by upstream's step, then the fork's `prepare-merge` phase flips it ready + enables auto-merge as before (brief draft window) |
| gh PR targeting | All `gh pr create/list/ready/merge` in factory workflows now pin `--repo <origin>` — no more accidental-upstream-PR risk from fork clones |
| CLI | Unknown flags hard-error (audit found none in cron); `archon continue` removed (unused); `workflow abandon`, `workflow wait`, `workflow runs`, `--dry-run`, `--adopt`, `--model`, `--input` now available |
| pipeline-health | Zombie-run cleanup becomes functional (status format verified unchanged; `abandon` now exists) |
| Bash nodes | `$node.output` substitutions are injected pre-quoted; the fork's double-quoted usages were fixed on the branch (triage-issue, pr-maintenance) |
| Target checkouts | Runs no longer copy `.archon/` into the target worktree; a run freezes its workflow/commands into its artifacts dir |
| smart-pr-review | Pre-existing missing `.archon/mcp/ntfy.json` validation error persists exactly as on 0.3.6 (notify node degrades the same way) |

---

## Stage 2 — sdlc pack adoption (separate project; user decision)

**Hard prerequisite:** run `archon serve` as a resident service (systemd unit) before invoking any workflow with a durable `wait:` (the sdlc delivery tail: ship/deliver/upkeep/stabilize). Without it, runs park at `status: paused` on pending CI and never resume; the launching CLI exits 0 printing "waiting for approval". Add a `workflow runs --status paused` sweep to pipeline-health regardless.

Mapping (factory workflow → sdlc):
| Today | Stage-2 equivalent | Notes |
|---|---|---|
| archon-fix-github-issue | `archon workflow run archon-ship "fix #N"` | triage→investigate→plan→deliver with built-in review lenses, CI await, ready-flip. Keep the cron auto-merge layer (ship does not merge). issue-pickup-cron pgrep patterns + invocation lines must change |
| archon-smart-pr-review | `archon workflow run archon-review --input <pr bindings>` | five attributable lenses + synthesize; verify input contract before switching pr-review-cron |
| archon-pr-maintenance | keep fork workflow | no sdlc equivalent (rebase/conflict/CI bot); already 0.10-native |
| archon-triage-issue | keep fork workflow | GH label plumbing is factory-specific; sdlc triage routes work items, doesn't label issues |
| archon-architect | keep (copy exists under our defaults/legacy) or retire toward periodic `archon-stabilize` | stabilize's assess runs large-tier diagnosis |
| security/test/requirements audits | keep fork workflows | fork-owned, 0.10-validated, no sdlc counterpart |

Model strategy under sdlc: the pack references only tiers. With Stage 1's tier config: small=haiku, medium=sonnet, large=claude-opus-5[1m]. **Fable has no tier slot** — options: per-run `--model large=claude-fable-5[1m]` on chosen invocations, or a per-repo `.archon/config.yaml` `tiers:` block in repos that warrant it. The fork-owned audit workflows keep their literal `claude-fable-5[1m]` pins either way (custom `@aliases` are refused in bundled-sourced workflows; literals are not).

Legacy-deletion pressure: upstream will delete `defaults/legacy/` in a future release, but our fork owns its copy — deletion only arrives via a future upstream merge we control. No urgency.
