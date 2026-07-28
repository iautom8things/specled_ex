<!-- agent-rules: generated v0.14.0 -->
---
description: ExUnit test patterns. Test cases, Mox, Oban, process lifecycle, LiveView assertions.
# Deliberately NOT write_only: knowing how to READ tests matters when debugging
# failures, so the native read-trigger earns its load. (mz, 2026-07-16)
paths:
  - "test/**/*.ex"
  - "test/**/*.exs"
---

## Test Cases

- `SpecLedEx.DataCase` — DB tests with Ecto Sandbox
- `SpecLedEx.ConnCase` — controller and LiveView tests

If the project lacks one of these cases, fall back to `ExUnit.Case` plus the
specific setup callbacks the test needs.

## Mox

Project mocks live in the `SpecLedEx.Mock*` namespace. Define them in
`test/support/mocks.ex` and stub behaviour with `Mox.stub/3` or `Mox.expect/4`.
Use `Mox.verify_on_exit!()` per-test setup to fail on missing expectations.

## Oban

In test env, Oban is typically configured `testing: :inline` — jobs execute
synchronously inside the test process. If the project uses `testing: :manual`,
use `assert_enqueued/1` + `Oban.drain_queue/1` instead.

## Process Lifecycle

Always use `start_supervised!/1` — guarantees cleanup between tests.

Never use `Process.sleep/1`:
- Waiting for a process to finish: `Process.monitor(pid)` then `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`
- Synchronizing before the next call: `_ = :sys.get_state(pid)` to drain the message queue

## LiveView Tests

- Use `Phoenix.LiveViewTest` and `LazyHTML` for assertions
- Drive interactions with `render_submit/2`, `render_change/2`
- Always reference element IDs: `assert has_element?(view, "#my-form")`
- Never test raw HTML strings
- Test outcomes, not implementation details
- Debug failing selectors with:

      document = LazyHTML.from_fragment(render(view))
      IO.inspect(LazyHTML.filter(document, "your-selector"), label: "Matches")
