---
tracker:
  kind: linear
  team_key: "GIKAI"
  required_labels:
    - "ai-task"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Blocked
    - QA
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/muraikenta/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued. Run the spec sufficiency check (Step 0.5) first.
  - If the ticket lacks enough detail to implement, draft the spec into the description and move to `Human Spec Review`.
  - Otherwise transition to `In Progress` and start implementation.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human PR Review`). Spec check is skipped when a PR is already attached.
- `In Progress` -> implementation actively underway.
- `Human Spec Review` -> AI drafted requirements into the description; waiting on human approval. Do not modify content; poll for state change.
- `Human PR Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Blocked` -> normally a terminal state for the agent (the run hit a real environmental/setup blocker; workpad records what is missing and the exact human action needed). When the agent IS dispatched on a `Blocked` issue, it can only be because a fresh comment arrived — switch to **Conversational mode** and answer without changing state.
- `QA` -> normally a terminal state for the agent (PR has merged, awaiting human/QA verification). When the agent IS dispatched on a `QA` issue, it can only be because a fresh comment arrived — switch to **Conversational mode** and answer without changing state.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> run Step 0.5 spec sufficiency check first.
     - If insufficient: draft the spec into the description, move to `Human Spec Review`, end the turn.
     - If sufficient (or a PR is already attached): immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow. If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Human Spec Review` -> wait and poll. Do not modify content; the human edits the description and moves the issue back to `Todo` when ready.
   - `Human PR Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Blocked` -> if invoked by an external dispatch (fresh comment), run **Conversational mode** (answer only, do not change state). Otherwise do nothing and shut down.
   - `QA` -> if invoked by an external dispatch (fresh comment), run **Conversational mode** (answer only, do not change state). Otherwise do nothing and shut down.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - run Step 0.5 spec sufficiency check; if insufficient, follow the spec-draft path and stop here for this ticket.
   - if sufficient, `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 0.5: Spec sufficiency check (Todo entry only)

Run this check on every `Todo` ticket before transitioning to `In Progress`. Skip it when a PR is already attached (those tickets follow the PR feedback loop, not the spec drafting loop).

Evaluate the ticket's description and active comments against this bar:

- Goal/intent: clear statement of what outcome the work should produce.
- Acceptance criteria: explicit "done" definition, either as checklist items or specific behavior the change must satisfy.
- Scope boundaries: in-scope vs out-of-scope is readable; the implementer can tell when to stop.
- No blocking unknowns: open questions, if any, are non-blocking ("nice to clarify" rather than "can't start without").

If all four pass, the spec is sufficient. Continue to Step 1.

If any fail, the spec is insufficient. Take the spec-draft path:

1. Read the existing description and active comments. Preserve any concrete intent the human already wrote.
2. Rewrite the issue description in place (description editing is allowed for this purpose) using this template:

   ```md
   ## Background

   <one or two sentences on the surrounding context the implementer needs>

   ## Goal

   <single-sentence outcome statement>

   ## Acceptance Criteria

   - [ ] <specific, testable criterion>
   - [ ] <specific, testable criterion>

   ## Out of Scope

   - <bounded list of things this ticket explicitly does not cover>

   ## Open Questions

   - <only include if there are genuinely open questions for the human>

   ---

   _Drafted by Codex for Human Spec Review. Edit this description as needed and move the issue back to `Todo` to start implementation._
   ```

3. Add a short comment summarizing what was drafted and what the human should review (no `## Codex Workpad` yet — that is created during implementation).
4. Move the issue to `Human Spec Review`.
5. End the turn. Do not create a workpad, branch, or any implementation artifacts.

Once the human approves by editing the description (if needed) and moving the issue back to `Todo`, the next poll re-enters this step. The spec will pass on the second visit and execution proceeds normally.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
    - Then run Step 1.5 (acknowledge incorporated comments) before any implementation work, so the human sees the reaction/reply promptly.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## Step 1.5: Classify and respond to incorporated comments

Whenever workpad reconciliation picks up a human comment that was not present in the prior turn, classify it and respond on the source channel so the author can see their input was processed.

### Reactions

Symphony's monitors automatically add a single `👀` reaction to every comment they detect, **before** they dispatch the agent. The reaction is the visible "I see this comment, the agent is on it" signal — agents do **not** add their own reactions on top. Drop the previous `✅` / `🤔` reaction conventions; if you find yourself reaching for them, just leave a substantive reply or update the workpad instead.

### Classification

For each new actionable comment (skip the agent's own `## Codex Workpad` and automated bot summaries like `みらいいぬ自動調査` / `coderabbitai`), tag it as one of:

- **Question / status request** — the author is asking for information ("now what?", "why X?", "current status?", "where is the test?"). The expected output is an answer, not a code change.
- **Information / FYI** — the author is sharing context that doesn't require action ("we're shipping tomorrow", "FYI the staging URL changed").
- **Feedback / instruction** — the author is asking for a behavior change in the code, tests, docs, or process ("rewrite as integration tests", "fix this bug", "follow approach X").
- **Mixed** — contains both a question and an instruction in the same body.

### Response by classification

**Question / status request**:

1. Compose a concrete, factual answer grounded in the workpad, recent commits (`git log`), PR state (`gh pr view`), test results, or referenced files. Cite specific commit SHAs, file paths with line numbers, or PR check names. No speculation, no vague "I will look into it" — if you don't have the answer, say so explicitly and either look it up before answering or open a follow-up question.
2. Post the answer on the **same channel** as the question:
   - Linear comment → reply via Linear MCP `commentCreate` with `parentId` pointing at the question's comment id (or top-level if the host doesn't expose a thread). Do **not** edit the workpad to hold the answer.
   - GitHub PR top-level comment → `gh pr comment <pr> --body "..."`.
   - GitHub PR inline review comment → `gh api repos/<owner>/<repo>/pulls/<pr>/comments/<comment_id>/replies -f body=...` to keep the thread intact.
3. Append a one-line entry to the workpad `Notes` ("Answered question on Linear comment <id>: <one-line summary>") so future turns have provenance.
4. **Do not produce code changes, branch updates, or pushes** purely to address the question. End the turn after answering and leave the issue in its current state (return to `Human PR Review` if a PR is already attached, otherwise the prior state).

**Information / FYI**:

1. Append a one-line entry to the workpad `Notes` capturing the information.
2. No reply, no code change, no state move (return to the prior state).

**Feedback / instruction**:

1. Update the workpad Plan / Acceptance Criteria / Validation to reflect the new direction.
2. Optionally post a short threaded reply when there is nuance the author should know (partial application, explicit deferral with reason, confirmation request).
3. Proceed with the normal execution / PR feedback sweep flow to land the change.

**Mixed**:

- Answer the question portion via the Question response above (reply).
- Apply the feedback portion via the Feedback response above (workpad update + execution).

### Identifying agent-authored replies

Linear and GitHub will post agent replies under whichever human account owns the API token / `gh auth login`, so the human reading the thread cannot tell at a glance that a comment came from Codex rather than from themselves. To remove that ambiguity, **every comment, reply, or thread post the agent authors must start with the following marker on its own line**:

```
> 🤖 Codex (Symphony) からの返信
```

(The blockquote keeps it visually distinct from the body and from human-authored comments.) After the marker, leave a blank line and then the substantive answer. This applies to:

- Linear top-level comments and threaded replies posted by the agent.
- GitHub PR top-level comments (`gh pr comment`).
- GitHub PR inline review-comment replies (`gh api .../pulls/<n>/comments/<id>/replies`).

Do **not** add the marker to the workpad (`## Codex Workpad` is already self-identifying), to reactions, or to any push-back / status-update copy that runs through the normal commit messages or PR descriptions. The marker is for human-readable replies only.

### Rules that apply across classifications

- Acknowledge per comment, not per batch. Each new comment that influenced the workpad gets its own reaction or reply.
- Use whichever Linear tool is available (Linear MCP `mcp__linear__*` reaction/comment mutations preferred; fall back to `linear_graphql` with `commentReactionCreate` / `commentCreate`).
- Do not duplicate. If the agent has already reacted to a comment in a prior turn, skip; if an existing reply already covers the same point, skip.
- Skip the agent's own `## Codex Workpad` comment and automated bot summaries — those are not human directives requiring acknowledgement.
- This step runs once per turn during workpad reconciliation. It must happen before implementation work so the author sees the acknowledgement promptly even if the turn is long-running.
- For pure question or FYI turns, do not move the issue out of its current state. The agent's job is to answer, not to claim work that wasn't requested.

### Conversational mode (non-`Human PR Review` states)

When the agent is dispatched on an issue whose current state is in the configured `tracker.conversational_states` set (default `["QA"]`, project workflows commonly add `"Blocked"` and `"Done"`), this is a turn triggered by a fresh human comment on either Linear or the linked GitHub PR — **not** a request for new feature/bug-fix code work.

The hard rule that applies in **every** conversational state:

- **Never make code changes, never create new commits, never modify branches, never `git push`.** The merged PR body must not be re-pushed. If a comment looks like it's asking for a code change, treat it as a question (answer with what would need to happen, do not act).
- Leave the issue in its current state — the orchestrator will not retry, the next turn fires only when a fresh comment arrives.
- If the human truly wants implementation work, they move the issue to `Rework` or `Todo`. Never infer that move from a conversational comment.

Within that hard rule, what the agent **may** do depends on which conversational state it landed on:

**`QA` (post-merge verification)** — the agent is allowed to perform QA-style validation work when the human asks for it. This includes:

- Checking out / running the merged branch, starting a dev server (`pnpm dev` etc.), exercising the feature.
- Taking screenshots / recordings of the running app via skills like `pr-screenshot`.
- Uploading QA artifacts (screenshots, videos) to R2 / configured artifact stores.
- Editing the PR body / description on the merged PR to attach QA results, screenshots, or a QA summary section.
- Posting QA reports as Linear comments or GitHub PR comments.
- Read-only inspection of any file, log, or runtime state.

These are explicitly **not** prohibited by the hard rule above — they don't change the merged code, don't push commits, and don't move the issue. If the comment asks for a QA action of this kind ("`pr-screenshot` で撮ってきて", "ローカルで動作確認して結果書いて"), do it.

**`Blocked` / `Done` / other configured conversational states** — read-only Q&A only. No dev server, no artifact upload, no PR body edits unless the human explicitly directed the action and the state semantics allow it. When in doubt, ask the human in a reply rather than acting.

For all conversational states, classify each new actionable comment per the Question / FYI / Feedback rules above, but with two adjustments:

- A "Feedback / instruction" comment that requests a permitted QA action (screenshot, server start, etc.) is still actionable — perform the action and report results. A "Feedback / instruction" comment that requests a code change is **not** actionable — answer with the equivalent of a Question response (what would need to change, what the human should do to trigger the rework path).
- The 👀 reaction is already on the source comment (added by the monitor). Don't add another reaction; focus on the substantive reply or QA artifact instead.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human PR Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update the workpad plan/checklist to include each feedback item and its resolution status.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Blocked` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, required non-GitHub auth is unavailable, or a sandbox/permission constraint prevents required write operations, move the ticket to `Blocked` with a short blocker brief in the workpad that includes:
  - what is missing or constrained,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.
- Do not route environmental blockers to `Human PR Review`; that state is reserved for human approval of an attached PR.

## Filing Symphony / workflow improvement requests

When you discover a gap, ambiguity, bug, or missing rule in Symphony itself or in this WORKFLOW.md — i.e., a meta-issue about *how the agent is supposed to operate*, not about the current ticket's product code — file it as a GitHub issue on the Symphony repo so it accumulates in one place across all future runs and does not pollute the product tracker.

Trigger examples:

- A workflow rule produced confusion or a wrong routing decision.
- A required state, label, or hook is missing.
- An orchestrator bug or limit (sandbox, polling, retry, dashboard) blocked or slowed the run.
- The prompt template lacks coverage for a recurring scenario.

Mechanics:

- Repo: `muraikenta/symphony`.
- Tool: `gh issue create --repo muraikenta/symphony --title "<title>" --body "<body>"`. Fall back to `gh api repos/muraikenta/symphony/issues -f title=... -f body=...` only if the higher-level command is unavailable.
- Before filing, search for duplicates: `gh issue list --repo muraikenta/symphony --state open --search "<keywords>"`. Skip if an open issue already covers the same point.
- Title: short and action-oriented. Examples: "Spec sufficiency check should account for empty description with rich comments", "Workspace creation fails when target repo's AGENTS.md mandates `git worktree`".
- Body: concise. Include three sections — **Context** (which Linear ticket surfaced this; the Linear URL is enough, do not paste workpad dumps), **What went wrong / what is missing** (one short paragraph), **Suggested change** (only when obvious; name file/section; skip if speculative).
- Do not include secrets, full prompts, or PII.
- After filing, append the issue URL to the workpad `Notes` so the human can find it later.

This is distinct from filing product follow-up Linear issues — those still go to Linear in the same project. This rule covers only Symphony itself.

## Step 2: Execution phase (Todo -> In Progress -> Human PR Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `Human PR Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `Human PR Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth or a sandbox/permission constraint per the blocked-access escape hatch, move to `Blocked` (not `Human PR Review`) with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Human PR Review`.

## Step 3: Human PR Review and merge handling

1. When the issue is in `Human PR Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `QA`. The QA team takes it from there and is responsible for moving it to `Done` once verified.

## Step 4: Rework handling

**Default behavior: incremental fix on the existing PR.** `Rework` means the reviewer wants changes to the current attempt, not a fresh restart. Reuse the existing branch, the existing PR, and the existing `## Codex Workpad`; layer the requested changes on top.

1. Re-read the full issue body, the workpad, the existing PR (commits, top-level/inline comments, review summaries), and all human comments. Identify the specific changes the reviewer asked for.
2. Move the issue to `In Progress` if not already there. Do **not** close the existing PR. Do **not** delete the workpad. Do **not** create a new branch.
3. Update the workpad's Plan / Acceptance Criteria / Validation in place to reflect the rework scope. Mark already-addressed items as resolved; add new items for the rework feedback.
4. Implement the requested changes on the existing branch. Commit incrementally with messages that reference the feedback (e.g., "fix: address review comment about X").
5. Run validation, push, and re-run the PR feedback sweep protocol until no actionable comments remain.
6. Move back to `Human PR Review` with the existing PR updated.

**Full reset (opt-in, rare).** Only when the reviewer explicitly requests a different approach, or the existing branch is unrecoverable (closed/merged PR, irreparable history, fundamentally wrong direction), do the following instead:

1. State in the workpad why a full reset is justified, citing the reviewer comment or branch state.
2. Close the existing PR with a comment pointing to the new branch.
3. Remove the existing `## Codex Workpad` comment from the issue.
4. Create a fresh branch from `origin/main`.
5. Run the normal kickoff flow: create a new workpad, build a fresh plan, execute end-to-end.

When in doubt, default to the incremental path. Reviewers expect their feedback applied to the PR they reviewed, not in a brand-new PR.

## Completion bar before Human PR Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking. The single exception is the Step 0.5 spec-draft path, where rewriting the description is the explicit deliverable for `Human Spec Review`.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `Human PR Review` unless the `Completion bar before Human PR Review` is satisfied.
- In `Human PR Review`, do not make changes; wait and poll.
- If state is terminal (`Blocked`, `QA`, `Done`, or any other configured terminal state), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
