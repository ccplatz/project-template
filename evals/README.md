# Evals

Evaluations for AI agent behavior. Unlike unit/integration tests (which verify
deterministic outputs: "given input X, output must be Y"), evals verify the
*non-deterministic* parts of agent behavior:

- Did the agent take the right trajectory of steps?
- Did it choose the right tools in the right order?
- Did the final response meet the quality bar?
- Did the agent follow project conventions correctly?

## Setting up evals

<!-- TODO: Document your eval setup here.

Evals are checked by labelled datasets, scoring rubrics, and LM judges — not by
deterministic assertions. They are the bridge from vibe coding to agentic engineering.

Options:
- Custom eval scripts that check agent output against curated test cases
- Playwright-based E2E scenarios that verify UI behavior after agent changes
- Rubric-based scoring for code quality, architecture adherence, etc.

Start small: pick one repetitive task the agent does and define a rubric for
what "good" looks like. Add evals for that task. Grow from there.
-->
