# Model Routing and Agent Work

This repository uses a mixed planner/executor model when the agent runtime
supports model selection.  The purpose is to spend frontier-model attention on
decisions that need it, keep the main context coherent, and move deterministic
work out of language models entirely.  Delegation is an efficiency technique;
it is not a way to evade account, product, or provider limits.

## Roles

The names below describe capability tiers.  Use the equivalent tier when a
runtime does not offer the named OpenAI model.

| Role | Default | Work |
|---|---|---|
| Planner and integrator | GPT-5.6 Sol | Architecture, security boundaries, ambiguous diagnosis, task decomposition, conflict resolution, escalation, and final review |
| Implementation executor | GPT-5.6 Terra | Bounded code changes, focused debugging, tests, and reviews with explicit acceptance criteria |
| Mechanical executor | GPT-5.6 Luna | Repository searches, inventories, fixture generation, formatting, and compression of large logs into evidence |
| Deterministic executor | No model | Builds, tests, file transfer, polling, retries, checksums, telemetry, and artifact collection |

Use the least expensive tier that has demonstrated it can meet the acceptance
test.  Do not send a task to a model merely because a model can run a command.

## Planner responsibilities

The planner owns one coherent outcome.  It must:

1. Inspect the actual repository constraints before decomposing work.
2. Keep security-sensitive credentials and external-control authority out of
   delegated coding processes.
3. Define independent, bounded assignments; do not delegate the same file to
   concurrent writers.
4. Review executor changes and evidence rather than accepting a success claim.
5. Run or inspect the final deterministic validation.
6. Report incomplete live verification distinctly from passing offline tests.

The planner may implement a small or tightly coupled change directly.  Agent
count is not a quality metric.

## Delegation packet

Every executor receives a compact packet containing:

```text
Objective:
Relevant files:
Constraints and prohibited actions:
Acceptance tests:
Scope/stopping condition:
Required output schema:
```

Do not forward the complete conversation or an undigested log unless it is
genuinely required.  A delegated context is commonly fresh or isolated, so the
packet must contain every policy and fact the executor needs.

Executors return:

```json
{
  "status": "passed | failed | blocked",
  "summary": "short result",
  "evidence": ["test name, file:line, or artifact path"],
  "changed_files": ["path"],
  "risks_or_followups": ["remaining concern"]
}
```

Raw command output belongs in an artifact or log.  The parent receives a
summary plus precise evidence locations.

## Routing rules

Use Sol when any of these is material:

- architecture or public-interface design;
- authentication, secrets, permissions, destructive actions, or cloud cost;
- several plausible diagnoses with different fixes;
- reconciliation of conflicting executor results;
- final integration review of a cross-cutting change.

Use Terra when the solution boundary is known and the task is a normal unit of
implementation, test construction, focused review, or evidence-led debugging.

Use Luna when success is mostly completeness and faithful reduction: locating
call sites, listing affected files, producing fixtures, checking repetitive
properties, or summarizing structured logs.

Use ordinary programs for predictable transformations and observations.
Examples include `guix build`, `go test`, remote command execution, heartbeats,
OCI lifecycle polling, JSONL sequencing, checksum generation, and retry loops.

## Parallelism and handoff

Parallel agents are appropriate only when their workstreams are independent,
their write sets do not overlap, and combining their results is cheaper than
doing the work serially.  Sequential work, multiple edits to the same file,
and tasks with rapidly changing shared state should stay with one executor.

Keep the planner in control when results need synthesis.  A full handoff is
appropriate only when a specialist should own the remainder of the task.  In
either form, pass the minimum context required and preserve one owner for the
final answer.

## Escalation

An executor stops and returns evidence when:

- the requested change crosses its stated scope;
- credentials, external writes, destructive operations, or spending become
  necessary but were not explicitly authorized;
- requirements conflict or an architectural choice is missing;
- the same implementation approach fails validation twice;
- a failure suggests a security or data-loss issue;
- its result conflicts with another executor's result.

The planner then decides whether to clarify, redesign, use a stronger model, or
stop.  Executors must not conceal uncertainty by widening scope.

## Measurement

Record the model/provider and, where available, model version, reasoning level,
token usage, latency, and test outcome for repeated workflows.  Promote or
demote a task class based on representative evaluations, not on the model name.
Lower token use counts as an improvement only when the same acceptance criteria
still pass.

## Sources and analogous systems

This policy follows the same broad patterns documented by several agent
runtimes:

- [OpenAI GPT-5.6 guidance](https://developers.openai.com/api/docs/guides/latest-model)
  assigns Sol to frontier work, Terra to balanced work, Luna to efficient
  high-volume work, and recommends explicit routing and bounded programmatic
  tool stages.
- [OpenAI Agents SDK orchestration](https://openai.github.io/openai-agents-python/multi_agent/)
  distinguishes manager-controlled agents-as-tools from handoffs and supports
  deterministic orchestration.
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents) use
  isolated specialist contexts, scoped tools, model selection, and summarized
  results.
- [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) warn
  that teams add coordination and token cost and work best on independent
  workstreams.
- [GitHub Copilot custom-agent orchestration](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/custom-agents)
  documents per-agent models and tools, isolated execution, lifecycle events,
  and the read-only-researcher/write-capable-implementer pattern.
