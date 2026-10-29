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
<For each milestone: tickets in order, each with size S/M/L, what it blocks, and its checks. A ticket is one commit when reasonable (< ~400 changed lines, one concern).>

### M1 <name>
| slug | title | size | blocked by | checks | guardrails |
|---|---|---|---|---|---|
| scaffold | ... | M | - | `npm test` | PM-3 |

## Pre-mortem: most probable failure reasons and their guardrails
<Filled from .autopilot/plan/premortem.md after the adversarial review. Every reason kept has a guardrail with a home: a KPI, a check, a ticket, or a rule in this plan.>

| # | Failure reason | P | Impact | Guardrail | Where it lives |
|---|---|---|---|---|---|
| PM-1 | ... | 0.6 | fatal | ... | ticket `scaffold` CHECKS / K1 / rule below |

## Rules for implementers and reviewers
- <project-specific rules derived from the guardrails: forbidden shortcuts, required tests, data sampled from real inputs>

## Open human decisions
- <decision, safe default shipped meanwhile, who decides>

## Approval
- Pre-mortem reviewed by: <models> on <date>
- Plan approved by: <owner> on <date>
