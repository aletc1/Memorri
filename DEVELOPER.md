# Developer guide

Memorri is built spec by spec with [Spec Kit](https://github.com/github/spec-kit). You do not need to know Spec Kit beforehand. This guide says exactly what to type for each situation.

Read `.specify/memory/constitution.md` (the project rules) and `docs/roadmap.md` (the order of work) once before you start.

## Contents
1. [One-time setup](#1-one-time-setup)
2. [How Spec Kit works here](#2-how-spec-kit-works-here)
3. [Start a new feature](#3-start-a-new-feature)
4. [Continue an unfinished feature](#4-continue-an-unfinished-feature)
5. [Change a spec that is already written](#5-change-a-spec-that-is-already-written)
6. [Fix a bug](#6-fix-a-bug)
7. [Make an architecture decision](#7-make-an-architecture-decision)
8. [Change a prompt, schema or model](#8-change-a-prompt-schema-or-model)
9. [Branches, commits and pull requests](#9-branches-commits-and-pull-requests)
10. [Definition of done](#10-definition-of-done)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. One-time setup

Do these once per Mac.

1. Install the tools (macOS 26+, Xcode, Homebrew and uv are required):
   ```bash
   uv tool install specify-cli
   brew install xcodegen
   specify --version && xcodegen --version
   ```
2. Install Ollama and pull the model the app uses: `ollama pull qwen3.8:27b-mlx`.
3. Create the local signing certificate. Without it, macOS forgets the Screen Recording permission on every rebuild:
   ```bash
   scripts/create-signing-certificate.sh
   ```
4. Install [Claude Code](https://claude.com/claude-code) and start it from the repository root: `cd Memorri && claude`. The Spec Kit commands are skills in `.claude/skills/` and load automatically.

Check that it worked: type `/speckit-` in Claude Code and confirm the commands appear. If they don't, restart Claude Code.

### Build and run the app

From the repository root, after the setup above:

```bash
xcodegen generate                                   # creates Memorri.xcodeproj (gitignored)
xcodebuild -scheme Memorri -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Memorri.app
swift test --package-path Packages/MemorriCore      # the unit tests
```

- The build fails with a message pointing to `scripts/create-signing-certificate.sh` if the "Memorri Local" identity is missing (setup step 3).
- Memorri has no Dock icon or main window. Look for its icon in the menu bar. Choose **Settings…** to see its window.
- On the first launch a window explains the Screen Recording permission. Choose **Open System Settings**, enable Memorri, and use **Relaunch Memorri** when it asks.
- To watch what the app does, run `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri"'` in another terminal. Use the full path: zsh has its own `log` command.
- To open the project in Xcode instead, run `xcodegen generate` and open `Memorri.xcodeproj`.
- Quick reset for testing the first launch: `tccutil reset ScreenCapture com.aletc1.memorri; defaults delete com.aletc1.memorri`.

### Where the app keeps its data

Captures and the database live in `~/Library/Application Support/Memorri/` (mode 0700, excluded from Time Machine):

```text
memorri.sqlite (+ -wal, -shm)        records (capture_events, capture_images, analysis_jobs, model_runs)
captures/<yyyy-MM>/<eventID>/        full-resolution and analysis pictures (HEIC)
staging/                             captures being written; emptied at every start
```

- Inspect the records: `sqlite3 "$HOME/Library/Application Support/Memorri/memorri.sqlite" "select status, display_count from capture_events order by captured_at desc limit 5;"`. Look at pictures only on a prepared test screen, because they show your real screen.
- Reset everything: quit Memorri, then `rm -rf "$HOME/Library/Application Support/Memorri"` and `defaults delete com.aletc1.memorri`.
- A database that could not be read is renamed `memorri.sqlite.damaged-<date>` in the same folder and never deleted.
- Debug builds accept `--simulate-free-bytes <n>` (for example `open -n Memorri.app --args --simulate-free-bytes 500000000`) to test the refusal when less than 1 GB is free.
- A running process does see a revoked Screen Recording permission through a real capture (ScreenCaptureKit error -3801). `CGPreflightScreenCaptureAccess()` keeps answering `true`, so do not use it after launch. Probes started from a shell are attributed to the terminal; start the app through LaunchServices (`open -n -W --stdout <file> Memorri.app --args …`).

### Ollama and the analysis queue

The app talks to a local Ollama server (spec 003). It cannot read screenshots yet; it only tests the model and runs test jobs.

- **Install**: `brew install ollama` (or the Ollama app), start it, then `ollama pull qwen3.8:27b-mlx`. The app chooses that model by itself on first use when it is installed. Settings → Ollama shows the connection status, the model picker (vision models only), thinking, the timeout, **Test the model** and the queue.
- **Local only**: the address must be `localhost`, `127.0.0.1` or `::1`; anything else is rejected. `OllamaURLSessionTransport.swift` is the only file allowed to use URLSession, so captured content cannot leave the Mac by accident. `NoNetworkTests` fails if any other file names it, including in a comment. See ADR 0011.
- **Fake server**: `python3 scripts/fake-ollama.py --port 11999 --mode ok|invalid|slow|error|flaky|hang [--delay 5] [--no-vision] [--no-capabilities] [--thinking]` stands in for Ollama when you need failure cases. Point Settings at `http://localhost:11999` (or `defaults write com.aletc1.memorri memorri.ollama.address http://localhost:11999` and relaunch; the model is `fake-vision:1b`). Reset with `http://localhost:11434`.
- **Logs**: categories `ollama` (`check …`, `request …`) and `analysis` (`job started/finished/failed`, `queue holding/resumed/paused`, `recovered running=<n>`). Info lines need `--level info`: `/usr/bin/log stream --level info --predicate 'subsystem == "com.aletc1.memorri" AND category == "analysis"'`.
- **Jobs and runs**: `sqlite3 "$HOME/Library/Application Support/Memorri/memorri.sqlite" "select state, attempts, failure_reason from analysis_jobs; select outcome, think, duration_ms from model_runs order by started_at desc limit 5;"`. Runs never hold picture data, and they are deleted with their capture.
- **Try the app without touching your data**: launch the binary with `CFFIXED_USER_HOME=/tmp/some-home` for a separate data folder. Preferences (`defaults`) are still shared, so restore the address and model afterwards.

## 2. How Spec Kit works here

A **spec** is a written description of one feature. You write it before the code. Each spec goes through the same steps, and each step is a slash command typed into Claude Code:

| Step | Command | What it produces | Required? |
|---|---|---|---|
| 1 | `/speckit-specify <description>` | `specs/NNN-name/spec.md`: what and why, user scenarios, acceptance criteria | Yes |
| 2 | `/speckit-clarify` | Up to 5 questions about gaps in the spec; answers are written back into `spec.md` | Recommended |
| 3 | `/speckit-plan` | `plan.md` and design files: how it will be built, which files, which ADRs apply | Yes |
| 4 | `/speckit-tasks` | `tasks.md`: an ordered task checklist | Yes |
| 5 | `/speckit-analyze` | A read-only report that finds contradictions between spec, plan and tasks | Recommended |
| 6 | `/speckit-implement` | Claude works through `tasks.md` and ticks each task off | Yes |
| 7 | `/speckit-converge` | Compares the code with the spec and adds tasks for whatever is still missing | When needed |

Other commands: `/speckit-checklist` (generate a requirements-quality checklist after planning) and `/speckit-taskstoissues` (turn tasks into GitHub issues).

Rules of thumb:
- **The spec says what and why. The plan says how.** Keep technology choices out of the spec.
- **Run the steps in order.** Each one reads the files the earlier ones wrote.
- **Read what Claude writes.** It is a draft. Edit `spec.md`, `plan.md` and `tasks.md` by hand if something is wrong, then continue.
- **One spec, one branch, one folder** (`specs/NNN-name/`). `NNN` counts up: 001, 002, 003.
- The order of specs is in `docs/roadmap.md`. Do not start one before the specs it depends on are done.

Note: this repository does not have Spec Kit's optional git extension installed, so **Spec Kit does not create branches for you**. You create the branch yourself (step 3.2 below).

## 3. Start a new feature

Use this for anything that adds behaviour: a new roadmap spec or a new capability.

1. **Pick the work.** For a roadmap spec, open `docs/roadmap.md` and copy its prompt. For anything else, write 3 to 6 sentences: what the user gets and why. Do not write how.
2. **Create a branch from an up-to-date `main`:**
   ```bash
   git checkout main && git pull
   git checkout -b 001-menubar-shell     # the next number, plus a short name
   ```
3. **Start Claude Code** in the repository root (`claude`).
4. **Write the spec:**
   ```
   /speckit-specify <paste the prompt or your description>
   ```
   Claude creates `specs/NNN-name/spec.md`. Read it. Check that the acceptance scenarios describe what you want, and that anything Claude was unsure about is marked `[NEEDS CLARIFICATION]`.
5. **Close the gaps:**
   ```
   /speckit-clarify
   ```
   Answer the questions. Repeat until Claude has no more, or you are satisfied.
6. **Make the plan:**
   ```
   /speckit-plan
   ```
   In the plan, check that it follows the constitution, links the ADRs it depends on, and matches the module layout in `CLAUDE.md`. If the plan makes a new architecture decision, do section 7 now.
7. **Make the task list:**
   ```
   /speckit-tasks
   ```
8. **Check consistency:**
   ```
   /speckit-analyze
   ```
   It only reports. Fix any problem it finds by editing the spec, plan or tasks, or ask Claude to. Rerun it until it is clean.
9. **Commit the design** before writing code:
   ```bash
   git add -A && git commit -m "docs(NNN): add spec, plan and tasks"
   ```
10. **Build it:**
    ```
    /speckit-implement
    ```
    Claude works through the tasks in order. Core logic in `MemorriCore` is written test-first: the test fails, then the code passes it. If it stops half-way, see section 4.
11. **Verify** against section 10 (Definition of done), update the status in `docs/roadmap.md`, push the branch, and open a pull request as described in section 9.

## 4. Continue an unfinished feature

Use this when you come back to a feature, or `/speckit-implement` stopped early.

1. **Switch to its branch:**
   ```bash
   git checkout 001-menubar-shell && git pull
   git status
   ```
2. **See what is left.** Open `specs/NNN-name/tasks.md`. Done tasks are ticked `[x]`. The first unticked task is where you continue.
3. **Start Claude Code** and run:
   ```
   /speckit-implement
   ```
   It skips completed tasks and continues with the next.
4. **If the code and the task list disagree**, for example you coded by hand, tasks were ticked wrongly, or the spec changed, run:
   ```
   /speckit-converge
   ```
   It compares the code with the spec, plan and tasks, and adds tasks for whatever is unbuilt. Then run `/speckit-implement` again.
5. **If Claude says the feature can't be found**, you are probably on the wrong branch or in the wrong folder. Check with `git branch --show-current` and `ls specs/`. Section 11 has the fix.

## 5. Change a spec that is already written

Use this when requirements change or you learn something during implementation.

**Before any code exists (or the change is small):**
1. Edit `specs/NNN-name/spec.md` by hand, or run `/speckit-specify` again with the updated description.
2. Run `/speckit-clarify` if the change opens new questions.
3. Run `/speckit-plan` and `/speckit-tasks` again so they match. Tasks already done stay done when you keep their text, and you can tick them by hand.
4. Run `/speckit-analyze`.

**After code exists:**
1. Update `spec.md` first, then `plan.md`. The spec is the source of truth, so never let it go stale.
2. Run `/speckit-converge`. It adds tasks for the new work.
3. Run `/speckit-implement`.

**If the change is big** (it replaces what the feature does): do not stretch the old spec. Start a new feature (section 3) and mark the old one as superseded in `docs/roadmap.md`.

## 6. Fix a bug

Spec Kit has no bug command. Choose by size.

**A. Small bug: the code does not do what the spec already says.** Most bugs.
1. Branch from `main`: `git checkout -b fix/short-description`.
2. **Write a failing test first** in `Packages/MemorriCore/Tests/` that reproduces it. Run `swift test --package-path Packages/MemorriCore` and confirm it fails.
3. Fix the code until the test passes.
4. Commit: `git commit -m "fix(area): what was wrong"`. Push the branch and open a pull request (section 9).

**B. The spec was wrong or incomplete: fixing it changes required behaviour.**
1. Update the affected `spec.md` (and `plan.md`) to describe the correct behaviour.
2. Follow flow A, using the updated spec as the reference for the test.
3. If tasks changed, run `/speckit-converge`.

**C. Large or cross-cutting bug: it needs design work.** Treat it as a new feature: section 3, with a name like `012-fix-duplicate-merging`.

**D. Wrong model behaviour** (a missed appointment, a wrong date, a duplicate item). This is a prompt or schema problem. Follow section 8.

**Write a postmortem** when the bug reached your real data, was caused by a wrong assumption, or teaches something worth keeping:
```bash
cp docs/postmortems/TEMPLATE.md docs/postmortems/$(date +%F)-short-title.md
```
Fill it in and commit it with the fix. If the lesson is a lasting rule, also write an ADR (section 7).

## 7. Make an architecture decision

Write an ADR when you choose a library, change how data is stored, change how modules talk, or reverse an earlier decision. Do not write one for ordinary code.

1. Find the next number: `ls docs/architecture/decisions/` (the last ADR is `0008`, so the next is `0009`).
2. Copy the template:
   ```bash
   cp docs/architecture/decisions/0000-template.md docs/architecture/decisions/0009-short-title.md
   ```
3. Fill in the context, the options you considered, the decision and its consequences. Set `Status: Proposed`.
4. Get a review. When it is agreed, set `Status: Accepted`.
5. Link the ADR from the spec or plan that depends on it.

**Never edit the decision of an Accepted ADR.** To change your mind, write a new ADR, set its status to Accepted, and change the old one to `Superseded by 00NN`.

## 8. Change a prompt, schema or model

Prompts and models decide whether the app finds the right items, so changes are measured, not guessed. The harness is `memorri-eval`, in `Packages/MemorriCore/Sources/memorri-eval` over `MemorriCore/Evaluation`; it runs the same `AnalysisPipeline` as the app's queue.

1. Make the change in `Extraction` and increase the prompt version (`ExtractionPrompts`) or schema version (`ExtractionSchemas`). Both are stored with every analysis.
2. Check that the app is not analysing (pause it from the menu) and that Ollama is running with the model chosen in Settings. Then run the set and keep the report:
   ```bash
   swift run --package-path Packages/MemorriCore memorri-eval run --out eval/out/before.json   # the old version
   # ...make the change...
   swift run --package-path Packages/MemorriCore memorri-eval run --out eval/out/after.json
   swift run --package-path Packages/MemorriCore memorri-eval compare eval/out/before.json eval/out/after.json
   ```
   The report lists precision, recall and field accuracy overall and by kind, classification, tags, context, reading accuracy, and every missed or unexpected finding with its dates. `run` refuses while the app's queue has a running job; `--allow-busy` overrides that and the report says so. `--only <case>` runs one case and `--replay <report.json>` scores the stored model answers again without calling the model (use it after changing only the code that resolves dates, durations, tags or contexts).
3. Precision and recall must not go down. If a case is new, add it first so the harness shows the failure before your fix.
4. **Golden cases** are folders with `picture.png`, `meta.json` (capture time, the Mac's time zone, context, windows, display size) and `expected.json` (kind, tags, context, drawn lines, findings). Only `eval/golden/synthetic/` is tracked; it is drawn by code (`memorri-eval generate-synthetic --out eval/golden/synthetic`, deterministic) so nothing real is stored. A case from a real session goes into the gitignored part of `eval/golden/`, never into a commit. Change a synthetic case in `MemorriCore/Evaluation/Synthetic*.swift` and regenerate.
5. `memorri-eval sweep-size` runs the set at 1024, 1536, 2048 and 3072 px and recommends the smallest size within 0.02 of the best (ADR 0017).
6. Put the before and after numbers in the pull request description.

To try the pipeline on one picture without capturing your screen, run a Debug build with `--ingest-picture <png>` (and `--ingest-windows <json>` for window titles), or `--ingest-case <golden case folder>`, then watch the app's log: `/usr/bin/log stream --predicate 'subsystem == "com.aletc1.memorri" && category == "extraction"'` shows `read`, `classify`, `extract`, `resolve`, `context` and `analysis stored` lines (never text, titles or tag values). `scripts/fake-ollama.py --mode extract` (also `extract-bad-citation`, `extract-empty`, `classify-unsure`) stands in for the model. Settings → Analysis shows each picture's state, kind, context (with a picker), tags and findings, and has the Contexts block.

## 9. Branches, commits and pull requests

**Never commit to `main`.** Every change, including docs and chores, goes on a branch and reaches `main` through a pull request.

**Branch names**
- Spec Kit features: `NNN-short-name`, for example `002-capture-and-storage`.
- Everything else: `<type>/short-description`, for example `fix/duplicate-merge`, `docs/developer-guide`, `chore/update-grdb`.

**Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org), in English:
```
<type>(<optional scope>): <short summary in the imperative>
```
| Type | Use for |
|---|---|
| `feat` | new behaviour for the user |
| `fix` | a bug fix |
| `docs` | documentation, specs, ADRs, postmortems |
| `refactor` | code change with no behaviour change |
| `test` | adding or fixing tests |
| `perf` | performance improvement |
| `build` / `ci` | build system, XcodeGen, CI |
| `chore` | anything else (tooling, dependencies, housekeeping) |

Examples: `feat(capture): capture each display separately`, `fix(reconcile): merge truncated titles`, `chore: bump GRDB`. For a breaking change, add `!` (`feat(db)!: rename entities table`) or a `BREAKING CHANGE:` footer.

**Opening a pull request**
1. Keep the branch up to date: `git fetch && git rebase origin/main`.
2. Push it: `git push -u origin <branch>`.
3. Open the PR: `gh pr create --base main`. The **PR title uses the same convention as a commit** (for example `feat(capture): capture each display separately`), because it becomes the commit message when the PR is squash-merged.
4. In the description, say what changed and why, link the spec folder (`specs/NNN-name/`) and any ADRs, and say how you verified it (tests run, acceptance scenarios checked, eval numbers for prompt changes).
5. Merge only when the Definition of done (section 10) is met. Use squash merge, then delete the branch.

Never include real screenshots or captured content in a commit or a PR.

## 10. Definition of done

A feature or fix is done when all of these are true:

- [ ] Every acceptance scenario in `spec.md` passes, in the running app or in `memorri-eval`.
- [ ] Every task in `tasks.md` is ticked.
- [ ] `swift test --package-path Packages/MemorriCore` passes.
- [ ] The app builds and runs: `xcodegen generate && xcodebuild -scheme Memorri -configuration Debug build`.
- [ ] No real captured data is committed (screenshots, captures, model output).
- [ ] New architecture decisions have an ADR.
- [ ] `docs/roadmap.md` shows the new status.
- [ ] Work is on a branch, not `main`, and commits and the PR title use English Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).

## 11. Troubleshooting

| Problem | Fix |
|---|---|
| `/speckit-...` commands don't appear | Run Claude Code from the repo root, then restart it. Check that `.claude/skills/speckit-specify/SKILL.md` exists. |
| Spec Kit says "Feature directory not found" | You are not on a feature branch. Run `git checkout NNN-name`. Alternatively set the folder for the session: `export SPECIFY_FEATURE_DIRECTORY=specs/NNN-name`. |
| `specs/` folder got a different name than my branch | Fine. The folder name comes from the short name Claude generates. `.specify/feature.json` records which folder is active. |
| macOS asks for Screen Recording permission again after a build | The app was not signed with the local certificate. Run `scripts/create-signing-certificate.sh`, then remove Memorri from System Settings → Privacy & Security → Screen Recording and grant it again. |
| `security find-identity` shows no valid identity | Open Keychain Access, find "Memorri Local", set Trust → Code Signing to Always Trust, then run the script again. |
| Ollama connection refused | Start it with `ollama serve` (or open the Ollama app) and check with `ollama list`. |
| The model returns text that isn't valid JSON | Check the model supports vision and structured output (`ollama show <model>`), lower the temperature, and see ADR 0005 for the fallback. |
| Everything in `.xcodeproj` looks wrong | It is generated and gitignored. Run `xcodegen generate` and never edit it by hand. |
| Unsure which step you're at | `git branch --show-current`, then open `specs/NNN-name/`. Only `spec.md` means run clarify or plan. With `plan.md`, run tasks. With `tasks.md`, run analyze or implement. |
