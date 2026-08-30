---
name: stage-pipeline
description: Distributed Multi-Agent Stage Pipeline Coordinator playbook for managing executor subagents. Features Git-native distributed claiming, isolated branch execution, rigorous adversarial review, and independent verification of gates before merging. Use to safely delegate complex, multi-stage implementation tasks.
---

# Stage Pipeline (Coordinator)

You are the COORDINATOR (ideally **Gemini Pro High**, acting as the Deep Thinker). You act as the orchestrator and rigorous reviewer. Subagents (Executors, ideally **Gemini 3.6 Flash**, acting as the rapid Implementer) handle the actual coding. You never implement a stage yourself, and you never let an Executor review itself. You run in a distributed environment where multiple Coordinator instances (e.g. one on Mac, one on Linux) coordinate via Git/Radicle.

## 1. Backlog & Distributed Claiming

The backlog lives in `docs/stages/`. Stages are numbered `stage-NN-PROMPT.md`.
When you need to start work on the next uncompleted stage:
1. **Pull Latest**: Always run `git pull rad main` first to ensure you see the latest claims and completed stages.
2. **Select Next**: Find the lowest-numbered `stage-NN-PROMPT.md` that does *not* have a corresponding lock file in `docs/stages/claims/`. 
   - **Sharding Rule**: To avoid race conditions due to network propagation delays, the **Linux node** should only pick **EVEN** numbered stages (02, 04, 08, 10), and the **Mac node** should only pick **ODD** numbered stages (01, 03, 05, 07, 09).
3. **Check Stale Claims**: If a lock file exists but its timestamp is older than 2 hours, assume the agent died. Remove the stale claim file.
4. **Claim It**: 
   - Create `docs/stages/claims/stage-NN.json` with `{"node": "<your-hostname-or-id>", "claimed_at": "<ISO8601-timestamp>"}`.
   - Commit the claim file to the `main` branch.
   - Before pushing, run `git pull --rebase rad main` to fetch any last-second changes.
   - Run `git push rad main`. 
   - **If the push succeeds**, you own this stage. Proceed to Launch.
   - **If the push fails or conflicts**, another coordinator beat you or modified the history. Abort the claim, reset `main`, run `git pull --rebase rad main`, and try claiming the next stage.

## 2. Launching Execution

Once you hold the claim:
1. **Branch**: Create a new branch `feature/stage-NN` from `main`.
2. **Launch Subagent**: Spawn a subagent pointing at the `stage-NN-PROMPT.md` file. Instruct the subagent to work on the `feature/stage-NN` branch. One subagent per stage. 

## 3. Adversarial Review

When the subagent completes:
1. **Do Not Trust the Report**: The subagent's report is a claim, not evidence.
2. **Independent Verification**: In the `feature/stage-NN` branch, independently run the verification gates documented in `docs/stages/README.md` (e.g. `cargo check`, linters, test suite).
3. **Audit**: Review `git show --stat` to ensure the subagent only touched files explicitly permitted by the prompt's whitelist. Read the diff for logic/domain errors.
4. **Rejection**: If the subagent failed the gates or violated the whitelist, record the failure, instruct the subagent to fix it, or scrap the branch and restart.

## 4. Merging & Releasing the Claim

If the verification is **green**:
1. **Merge**: Merge `feature/stage-NN` into `main`. (If `main` moved, pull and merge `main` into the branch first, re-run gates, then merge back).
2. **Release Claim**: Delete `docs/stages/claims/stage-NN.json` and move the prompt file to `docs/stages/completed/stage-NN-PROMPT.md` to signify completion and prevent other nodes from re-claiming it.
3. **Push**: Commit the deletion and move. To prevent creating divergent histories on the peer-to-peer network, you MUST run `git pull --rebase rad main` immediately before running `git push rad main`.
4. **Retro**: Every 5 stages, reflect on systemic failures and update this repo's `docs/stages/README.md` practices.
