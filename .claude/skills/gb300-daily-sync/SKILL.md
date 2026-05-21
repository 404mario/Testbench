---
name: gb300-daily-sync
description: Interactively commit + push the day's changes to 404mario/Testbench. Detects sensitive filenames (.env / *.key / id_rsa / token / secret) and big files (>50MB likely build artifacts). Does NOT use git add -A; user must explicitly stage. Use when the user says "今天结束 / commit / push / 同步 / daily snapshot / 推一下".
---

# GB300 Daily Sync

**Trigger when**: User wants to commit/push the day's work; end-of-day snapshot; "推一下 / push 一下".

**Action**:

```bash
# Interactive (default)
bash scripts/daily_snapshot.sh

# Dry-run (just see status, no add/commit/push)
bash scripts/daily_snapshot.sh --dry-run

# With preset commit message
bash scripts/daily_snapshot.sh --message "scripts: add fabric evidence collector"
```

**What the script does**:
1. Shows `git status` + `git diff --stat HEAD` + untracked file list
2. **Sensitive-file sniff**: flags filenames matching `.env|credential|secret|password|token|*.pem|id_rsa|id_ed25519|*.key`
3. **Big-file sniff**: flags any pending file >50MB (likely build artifact)
4. Opens an interactive sub-shell so user can `git add -p` or `git add <file>` deliberately
5. Confirms staged file list
6. Asks for commit message (default: `docs/scripts: daily snapshot YYYY-MM-DD`)
7. Commits
8. Asks Y/N before `git push origin main`

**Hard limits**:
- MUST NEVER `git add -A` or `git add .` (per project policy — risk of catching secrets/binaries)
- MUST NEVER `git commit --amend` on already-pushed commits
- MUST NEVER `git push --force` to main
- MUST NEVER bypass pre-commit hooks (`--no-verify`)

**Before invoking**, sanity-check:
```bash
git status                    # any unexpected changes?
file ~/bench/bench_gemm 2>/dev/null  # if newly built, don't commit it
ls diagnostics/ 2>/dev/null   # fabric evidence may contain IPs — review before commit
```

**Pre-commit reminders**:
- `result/`, `*.log`, build artifacts → already in `.gitignore`
- `diagnostics/fabric_evidence_*/` → in `.gitignore` (raw evidence has IPs, scrub before sharing)
- Spec changes? Make sure `spec/GB300_specs.json` (flat) and `spec/GB300_specs.full.json` (nested) are consistent
- New script? `chmod +x` and add to repo's index of common entry points in `CLAUDE.md` if it's user-facing

**After push**:
- Update plan file `/root/.claude/plans/gb300-compute-node-jaunty-comet.md` if status changed
- Update `MEMORY.md` if any project facts shifted
