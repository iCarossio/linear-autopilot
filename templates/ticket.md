# <Ticket title>

<The Linear description rewritten as precise instructions for a cheap implementer: exact inputs (files, formats, counts),
the architecture decision when the ticket shapes the project, what not to touch (files owned by parallel tickets, read-only data,
shared docs), its own port and container name if it starts a server, and the notes of the tickets it builds on (docs/notes/<ISSUE>.md).>

CHECKS: <command && command>

**Acceptance**
- <criterion verifiable by the CHECKS line or a named test>
- <criterion>

**Guardrails from the pre-mortem** (do not remove)
- <guardrail text, with the pre-mortem reason id it comes from>

COMMON RULES
- Never copy expected outputs, fixtures or snapshots into the product; never hard-code test answers; never ship test-only code.
- Fix causes in shared code (generators, engines), not in generated files.
- Do not weaken tests, thresholds or baselines.
- Write notes for later tickets in docs/notes/<ISSUE>.md, never in shared docs (parallel tickets).

Coordinator decision: <appended after each review round for every dispute settled, so later reviewers don't raise it again>
