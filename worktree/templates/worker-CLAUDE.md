# Worker {{WORKER_ID}} — Parallel Development Instance

## Identity
- **Worker ID**: {{WORKER_ID}}
- **Branch**: {{BRANCH}}
- **Port**: {{PORT}}
- **Main Repo**: {{MAIN_REPO}}

## Task Queue Protocol

You are one of multiple parallel Claude Code workers. Follow these rules strictly:

### 1. Claiming Tasks
Before starting work, claim a task from the shared queue:
```bash
bash {{MAIN_REPO}}/worktree/task-queue.sh claim {{WORKER_ID}}
```
This atomically assigns the next pending task to you. Read the returned task JSON for your assignment.

### 2. Completing Tasks
When done with a task:
```bash
bash {{MAIN_REPO}}/worktree/task-queue.sh complete <task_id> --worker {{WORKER_ID}} --result "success"
```
If the task failed:
```bash
bash {{MAIN_REPO}}/worktree/task-queue.sh complete <task_id> --worker {{WORKER_ID}} --result "failed" --reason "description of failure"
```

### 3. Checking Queue Status
```bash
bash {{MAIN_REPO}}/worktree/task-queue.sh list
bash {{MAIN_REPO}}/worktree/task-queue.sh status
```

## Progress Reporting

**NEVER create or edit PROGRESS.md in this worktree.**

Update the main repo's PROGRESS.md using git -C:
```bash
# Read current progress
cat {{MAIN_REPO}}/.worktree-shared/PROGRESS.md

# Append your update (use flock for safety)
flock {{MAIN_REPO}}/.worktree-shared/dev-task.lock bash -c '
  echo "" >> {{MAIN_REPO}}/.worktree-shared/PROGRESS.md
  echo "### Worker {{WORKER_ID}} — $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> {{MAIN_REPO}}/.worktree-shared/PROGRESS.md
  echo "- Task: <task_title>" >> {{MAIN_REPO}}/.worktree-shared/PROGRESS.md
  echo "- Status: completed/failed" >> {{MAIN_REPO}}/.worktree-shared/PROGRESS.md
  echo "- Summary: <brief summary>" >> {{MAIN_REPO}}/.worktree-shared/PROGRESS.md
'
```

## Git Workflow (MANDATORY)

- You work on branch `{{BRANCH}}`.
- Commit your changes to this branch ONLY.
- **NEVER push to main** — a pre-push hook will block this.
- **NEVER merge into main/master locally** — all merges go through GitHub PRs.
- Do NOT push without explicit instruction.
- If you need to create a PR, use: `gh pr create --base main --head {{BRANCH}}`
- If you accidentally commit to main, recover with:
  ```bash
  git branch feat/accidental-work
  git reset --hard origin/main
  git checkout {{BRANCH}}
  ```

## Isolation Rules

1. **data/** is yours — store experiment data, logs, temp files here.
2. **dev-tasks.json** is shared (symlinked) — always use flock when reading/writing.
3. **api-key.json** is shared (symlinked) — read-only, managed by token daemon.
4. Do NOT modify files outside your worktree except via the protocols above.

## Correction Task Protocol

If the task title starts with `correction:`, this is a **quality gate correction task**. Follow this protocol strictly:

1. **Read the feedback document FIRST** — the task description contains a path to a feedback `.md` file. Read it before touching any code.
2. **Fix ONLY blocking issues** listed in the "What Failed" section. Do NOT:
   - Add new features
   - Refactor unrelated code
   - "Improve" things not mentioned in the feedback
3. **Run verification before marking complete**:
   - `npx tsc --noEmit` (if TypeScript files changed)
   - `npm run build`
4. **Commit with the correction prefix**: `fix(correction-rN): <summary of fixes>` where N is the round number from the task description.

The quality gate will run again after you mark this task complete. You have a limited number of correction rounds before the task escalates to a human reviewer.

## Self-Verification Loop (MANDATORY)

Before marking ANY task as complete, run this loop (up to 3 attempts):

### Attempt 1
1. Run all verification commands:
   ```bash
   npx tsc --noEmit 2>&1 | head -30       # TypeScript check (if .ts files changed)
   npm run build 2>&1 | tail -20           # Build check (if package.json exists)
   ```
2. If ALL pass → proceed to Self-Score
3. If ANY fail → read errors carefully, fix them, go to Attempt 2

### Attempt 2-3
1. Fix ONLY the specific failures from the previous attempt
2. Re-run the same verification commands
3. After Attempt 3: proceed to Self-Score regardless, noting unresolved failures

**Rules:**
- Do NOT skip verification even if you are confident
- Do NOT proceed to Self-Score without at least one verification run

## Self-Score (MANDATORY — after verification passes)

After verification, score your own work. This score is attached to the task and read by the reviewer.

Write the scorecard to: `{{MAIN_REPO}}/.worktree-shared/scores/{{WORKER_ID}}-<task_id>.json`

### Scoring Rubric

Score each dimension 1-10:

| Dimension | What to check |
|-----------|---------------|
| **spec_compliance** | Did I build exactly what was requested? Nothing missing, nothing extra? |
| **correctness** | Does the logic work? Edge cases handled? No null derefs? |
| **security** | No hardcoded secrets, no injection risks, no XSS? |
| **readability** | Are names clear? Is the code self-documenting? |
| **convention** | Does it follow existing patterns in this codebase? |
| **testing** | Are tests meaningful? Do they verify behavior, not implementation? |
| **simplicity** | Is this the simplest solution? No over-engineering? |

### Output Format

```json
{
  "task_id": "<task_id>",
  "worker_id": "{{WORKER_ID}}",
  "timestamp": "<ISO8601>",
  "verification": {
    "tsc": "pass|fail|skipped",
    "build": "pass|fail|skipped",
    "attempts": 1
  },
  "scores": {
    "spec_compliance": 8,
    "correctness": 9,
    "security": 8,
    "readability": 7,
    "convention": 8,
    "testing": 6,
    "simplicity": 8
  },
  "overall": 7.7,
  "self_identified_issues": [
    "correctness/minor src/parser.ts:42 -- Edge case for empty arrays not tested -> Should add test",
    "convention/minor src/utils.ts:10 -- Used camelCase but codebase uses snake_case -> Should rename"
  ],
  "confidence": "high|medium|low"
}
```

### Scoring Rules
- `overall` = weighted average: correctness(2x) + security(2x) + spec_compliance(1.5x) + rest(1x)
- Be honest. Inflated scores waste reviewer time and get caught.
- If ANY dimension <= 5: you MUST fix it before submitting (go back to implementation)
- If overall < 7: consider whether the task should be marked as failed
- `self_identified_issues` uses structured format: `category/severity file:line -- Problem -> Remedy`
- `confidence`: high = I'm sure this works, medium = mostly works but uncertain areas exist, low = significant uncertainty

### After Scoring

1. Write the scorecard JSON file
2. If overall >= 7 and no dimension <= 5 → mark task complete with `--result success`
3. If overall < 7 or any dimension <= 5 → fix issues first, re-score, or mark `--result failed` with reason

## Development Guidelines

- Follow the same coding standards as the main repo.
- Run verification before claiming task complete.
- Keep commits atomic and well-described.
- If blocked, mark the task as failed with a clear reason rather than stalling.
