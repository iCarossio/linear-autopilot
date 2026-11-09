# <Project name>

**Owner:** <who decides> · **Deadline:** <date> · **Repo:** <path or URL> · **Default branch:** <main>

## Goal
<One paragraph: what exists at the deadline that does not exist today, for whom, and why now.>

## Expectations and KPIs
Each KPI is measurable at the deadline with the command or number in the "How measured" column. A KPI without a measurement is not accepted.

| # | KPI | Target | How measured (command / query / count) | Owner |
|---|---|---|---|---|
| K1 | <e.g. parity with the old site> | <e.g. 100% of 420 pages pass the visual diff> | `npm run parity -- --all` -> 0 failures | autopilot |
| K2 | <e.g. performance> | <p95 < 200 ms on /api/search> | `k6 run perf/search.js` | autopilot |
| K3 | <e.g. delivery> | <all P1 tickets Done by date> | Linear project view | owner |

## Non-goals
- <what is explicitly out of scope, so reviewers do not ask for it>

## Constraints
- <stack, conventions, data that must not change, human-only decisions, budget: subscriptions and free tiers only>

## Architecture and key decisions
- <decision, alternative rejected, why>

## Milestones and tickets
<One or more major milestones, in order. Each is a shippable outcome with its own KPIs or acceptance (measurable like
the project KPIs), its own Linear milestone and its own progress bar and ETA (`bin/eta`). Tickets: size S/M/L, what
blocks them (blockers may cross milestones), checks. A ticket is one commit when reasonable (< ~400 changed lines, one
concern). A milestone added later goes through `bin/milestone add`, which appends its section here.>

### M1 <name>
<What exists when this milestone is done, for whom.>

| # | KPI / acceptance | Target | How measured |
|---|---|---|---|
| M1-K1 | <e.g. the thin loop runs end to end> | <1 run green> | `make e2e` -> exit 0 |

| slug | title | size | blocked by | checks | guardrails |
|---|---|---|---|---|---|
| scaffold | ... | M | - | `npm test` | PM-3 |

### M2 <name>
| # | KPI / acceptance | Target | How measured |
|---|---|---|---|
| M2-K1 | ... | ... | ... |

| slug | title | size | blocked by | checks | guardrails |
|---|---|---|---|---|---|
| api | ... | L | scaffold | `npm test` | PM-1 |

## Pre-mortem: most probable failure reasons and their guardrails
<Filled from .autopilot/plan/premortem.md after the adversarial review. Every reason kept has a guardrail with a home: a KPI, a check, a ticket, or a rule in this plan.>

| # | Failure reason | P | Impact | Guardrail | Where it lives |
|---|---|---|---|---|---|
| PM-1 | ... | 0.6 | fatal | ... | ticket `scaffold` CHECKS / K1 / rule below |

## Rules for implementers and reviewers
- <project-specific rules derived from the guardrails: forbidden shortcuts, required tests, data sampled from real inputs>

## Open human decisions
- <decision, safe default shipped meanwhile, who decides>

## Decision log
Every change of plan after the first draft, with its source: an answer of the user, a pre-mortem reason, a plan or code
review finding, a re-plan signal, a quota limit, a safe default for an open human decision. Written with `bin/decision add`
before the change is acted on, then mirrored in Linear. A change of plan without a row here is a defect.

| # | Date | Change (before -> after) | Why | Source | Decided by | Affects | Linear |
|---|---|---|---|---|---|---|---|

## Approval
- Pre-mortem reviewed by: <models> on <date>
- Plan approved by: <owner> on <date>
