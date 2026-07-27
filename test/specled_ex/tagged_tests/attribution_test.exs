defmodule SpecLedEx.TaggedTests.AttributionTest do
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.tagged_tests.attribution_partial_outcomes"]

  alias SpecLedEx.TaggedTests.Attribution

  defp started(cover, id, file, line),
    do: %{
      "event" => "test_started",
      "id" => id,
      "file" => file,
      "line" => line,
      "spec" => [cover]
    }

  defp finished(cover, id, file, line, state),
    do: %{
      "event" => "test_finished",
      "id" => id,
      "file" => file,
      "line" => line,
      "spec" => [cover],
      "state" => state
    }

  defp suite_finished, do: %{"event" => "suite_finished"}

  describe "read_artifact/1" do
    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "returns :absent for a missing path" do
      assert Attribution.read_artifact(
               Path.join(System.tmp_dir!(), "nope_#{:erlang.unique_integer([:positive])}.jsonl")
             ) ==
               :absent
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "returns {:ok, []} for an existing but empty artifact (compile-cost signal)" do
      path = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, "")
      on_exit(fn -> File.rm_rf!(path) end)

      assert Attribution.read_artifact(path) == {:ok, []}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "parses JSONL events and tolerates a trailing partial line" do
      path = Path.join(System.tmp_dir!(), "jsonl_#{System.unique_integer([:positive])}.jsonl")

      File.write!(
        path,
        Jason.encode!(started("req.a", "M.t", "test/a.exs", 3)) <>
          "\n" <> Jason.encode!(suite_finished()) <> "\n{\"event\":\"test_star"
      )

      on_exit(fn -> File.rm_rf!(path) end)

      assert {:ok, events} = Attribution.read_artifact(path)
      assert length(events) == 2
      assert Attribution.suite_finished?(events)
    end
  end

  describe "attribute/2 classification matrix" do
    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "a recorded pass with no failure is :passed" do
      events = [
        started("req.a", "M.a", "test/a.exs", 3),
        finished("req.a", "M.a", "test/a.exs", 3, "pass"),
        suite_finished()
      ]

      assert Attribution.attribute(events, ["req.a"]) == %{"req.a" => :passed}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "a recorded failure wins over a recorded pass for the same cover" do
      events = [
        finished("req.a", "M.pass", "test/a.exs", 3, "pass"),
        finished("req.a", "M.fail", "test/a.exs", 9, "failed"),
        suite_finished()
      ]

      assert Attribution.attribute(events, ["req.a"]) ==
               %{"req.a" => {:failed, ["test/a.exs:9 (M.fail)"]}}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "an invalid state also counts as failed" do
      events = [finished("req.a", "M.a", "test/a.exs", 3, "invalid"), suite_finished()]

      assert Attribution.attribute(events, ["req.a"]) ==
               %{"req.a" => {:failed, ["test/a.exs:3 (M.a)"]}}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "started-but-never-finished with no suite_finished is an in-flight hang-suspect SET" do
      events = [
        started("req.a", "M.hang1", "test/a.exs", 42),
        started("req.a", "M.hang2", "test/a.exs", 50)
      ]

      assert %{"req.a" => {:in_flight, suspects}} = Attribution.attribute(events, ["req.a"])

      assert Enum.sort(suspects) ==
               ["test/a.exs:42 (M.hang1)", "test/a.exs:50 (M.hang2)"]
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "no events and no suite_finished is :not_started (timeout remainder)" do
      assert Attribution.attribute([], ["req.a"]) == %{"req.a" => :not_started}

      events = [started("req.other", "M.o", "test/o.exs", 1)]
      assert Attribution.attribute(events, ["req.a"]) == %{"req.a" => :not_started}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "no pass/fail evidence with suite_finished present is :not_executed" do
      # silent cover on a completed run
      events = [finished("req.other", "M.o", "test/o.exs", 1, "pass"), suite_finished()]
      assert Attribution.attribute(events, ["req.a"]) == %{"req.a" => :not_executed}

      # skipped/excluded-only cover on a completed run
      skipped = [
        started("req.a", "M.a", "test/a.exs", 3),
        finished("req.a", "M.a", "test/a.exs", 3, "skipped"),
        suite_finished()
      ]

      assert Attribution.attribute(skipped, ["req.a"]) == %{"req.a" => :not_executed}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "credits a cover by test location when its runtime spec tag was shadowed" do
      # ExUnit collapses multiple @tag spec: lines to the last one, so a cover
      # declared via a shadowed tag never appears in the event's spec list even
      # though its test ran. The scanner-supplied location backfills it.
      events = [
        finished("effective.id", "M.t", "test/a.exs", 42, "pass"),
        suite_finished()
      ]

      locations = %{"shadowed.id" => [{"test/a.exs", 42}]}

      assert Attribution.attribute(events, ["shadowed.id"], locations) == %{
               "shadowed.id" => :passed
             }

      # A genuinely skipped test at the mapped location stays :not_executed.
      skipped = [finished("effective.id", "M.t", "test/a.exs", 42, "skipped"), suite_finished()]

      assert Attribution.attribute(skipped, ["shadowed.id"], locations) ==
               %{"shadowed.id" => :not_executed}
    end

    @tag spec: "specled.tagged_tests.attribution_partial_outcomes"
    test "distributes independent outcomes across many covers from one run" do
      events = [
        finished("req.pass", "M.p", "test/p.exs", 1, "pass"),
        finished("req.fail", "M.f", "test/f.exs", 2, "failed"),
        started("req.hang", "M.h", "test/h.exs", 3),
        finished("req.skip", "M.s", "test/s.exs", 4, "excluded")
        # no suite_finished — the run was killed
      ]

      attribution =
        Attribution.attribute(events, ["req.pass", "req.fail", "req.hang", "req.skip", "req.none"])

      assert attribution == %{
               "req.pass" => :passed,
               "req.fail" => {:failed, ["test/f.exs:2 (M.f)"]},
               "req.hang" => {:in_flight, ["test/h.exs:3 (M.h)"]},
               # excluded-only but no suite_finished → treated as a timeout remainder
               "req.skip" => :not_started,
               "req.none" => :not_started
             }
    end
  end

  describe "self-identifying descriptors" do
    @describetag spec: "specled.tagged_tests.descriptors_self_identify"

    test "a failing test is named by location AND by the formatter's event id" do
      events = [
        finished(
          "req.a",
          "DocsLintTest.test a code IS flagged",
          "test/docs_lint.exs",
          255,
          "failed"
        ),
        suite_finished()
      ]

      # The id is what survives a tree that moved. A gate report generated
      # against tree state A and read against state B points its line at a
      # different test — or at blank space — and without the id the report is
      # indistinguishable from one that fabricated the line.
      assert Attribution.attribute(events, ["req.a"]) ==
               %{
                 "req.a" =>
                   {:failed, ["test/docs_lint.exs:255 (DocsLintTest.test a code IS flagged)"]}
               }
    end

    test "a hang suspect is named by location AND by the formatter's event id" do
      events = [started("req.a", "SlowTest.test hangs", "test/slow.exs", 7)]

      assert Attribution.attribute(events, ["req.a"]) ==
               %{"req.a" => {:in_flight, ["test/slow.exs:7 (SlowTest.test hangs)"]}}
    end

    test "a descriptor degrades to whichever half the event carries" do
      no_id = [finished("req.a", nil, "test/a.exs", 3, "failed"), suite_finished()]
      assert Attribution.attribute(no_id, ["req.a"]) == %{"req.a" => {:failed, ["test/a.exs:3"]}}

      no_line = [finished("req.b", "M.t", "test/b.exs", nil, "failed"), suite_finished()]

      assert Attribution.attribute(no_line, ["req.b"]) ==
               %{"req.b" => {:failed, ["test/b.exs (M.t)"]}}

      no_file = [finished("req.c", "M.t", nil, nil, "failed"), suite_finished()]
      assert Attribution.attribute(no_file, ["req.c"]) == %{"req.c" => {:failed, ["M.t"]}}

      neither = [finished("req.d", nil, nil, nil, "failed"), suite_finished()]

      assert Attribution.attribute(neither, ["req.d"]) == %{
               "req.d" => {:failed, ["unknown test"]}
             }
    end

    test "an empty id and a non-integer line degrade like the absent ones" do
      # A present-but-empty id is not an id. Without the `id != ""` guard the
      # descriptor renders a bare `(...)` that reads like a truncated name.
      empty_id = [finished("req.e", "", "test/e.exs", 3, "failed"), suite_finished()]

      assert Attribution.attribute(empty_id, ["req.e"]) ==
               %{"req.e" => {:failed, ["test/e.exs:3"]}}

      # JSON encoders do emit stringified numbers. A non-integer line must fall
      # to the file-only arm rather than interpolate into a location that looks
      # authoritative and is not.
      string_line = [finished("req.f", "M.t", "test/f.exs", "9", "failed"), suite_finished()]

      assert Attribution.attribute(string_line, ["req.f"]) ==
               %{"req.f" => {:failed, ["test/f.exs (M.t)"]}}
    end
  end

  describe "merge/2" do
    @tag spec: "specled.tagged_tests.resume_pass_over_remainder"
    test "first run's observed outcome wins over the resume run" do
      first = %{"req.a" => :passed, "req.b" => {:failed, ["test/b.exs:2"]}}
      resume = %{"req.a" => {:failed, ["test/a.exs:1"]}, "req.b" => :passed}

      assert Attribution.merge(first, resume) == %{
               "req.a" => :passed,
               "req.b" => {:failed, ["test/b.exs:2"]}
             }
    end

    @tag spec: "specled.tagged_tests.resume_pass_over_remainder"
    test "resume run fills the first run's never-started remainder" do
      first = %{"req.a" => :passed, "req.b" => :not_started, "req.c" => :not_started}
      resume = %{"req.b" => :passed, "req.c" => {:in_flight, ["test/c.exs:9"]}}

      assert Attribution.merge(first, resume) == %{
               "req.a" => :passed,
               "req.b" => :passed,
               "req.c" => {:in_flight, ["test/c.exs:9"]}
             }
    end

    @tag spec: "specled.tagged_tests.resume_pass_over_remainder"
    test "covers present in only one run are carried through unchanged" do
      first = %{"req.a" => :not_started}
      resume = %{"req.b" => :passed}

      assert Attribution.merge(first, resume) == %{
               "req.a" => :not_started,
               "req.b" => :passed
             }
    end

    @tag spec: "specled.tagged_tests.resume_pass_over_remainder"
    test "an empty resume map leaves the first run untouched" do
      first = %{"req.a" => :passed, "req.b" => :not_started}

      assert Attribution.merge(first, %{}) == first
    end
  end
end
