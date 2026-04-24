defmodule SpecLedEx.PolicyFilesTest do
  use SpecLedEx.Case
  @moduletag spec: ["specled.policy_files.change_analysis_delegates", "specled.policy_files.classify_kinds", "specled.policy_files.co_change_rule_total", "specled.policy_files.plan_docs_excluded", "specled.policy_files.priv_defaults_to_lib", "specled.policy_files.priv_plts_is_generated"]

  alias SpecLedEx.PolicyFiles

  describe "classify/1 totality" do
    @tag spec: "specled.policy_files.classify_kinds"
    test "returns one of the known atoms for any path" do
      paths = [
        "lib/x.ex",
        "test/x_test.exs",
        "docs/x.md",
        "priv/static/app.css",
        "priv/plts/dialyzer.plt",
        "weird/top/level/file.txt",
        "README.md",
        "mix.exs"
      ]

      for path <- paths do
        kind = PolicyFiles.classify(path)
        assert kind in [:lib, :test, :doc, :generated, :unknown],
               "#{path} classified as #{inspect(kind)}"
      end
    end
  end

  describe "classify/1 priv behavior" do
    @tag spec: "specled.policy_files.priv_defaults_to_lib"
    @tag spec: "specled.policy_files.classify_kinds"
    test "priv/repo/migrations/*.exs is :lib (priv_repo_migrations_is_lib)" do
      assert PolicyFiles.classify("priv/repo/migrations/20260401_add_users.exs") == :lib
    end

    @tag spec: "specled.policy_files.priv_defaults_to_lib"
    test "priv/static and priv/gettext are :lib" do
      assert PolicyFiles.classify("priv/static/app.css") == :lib
      assert PolicyFiles.classify("priv/gettext/en/LC_MESSAGES/default.po") == :lib
    end

    @tag spec: "specled.policy_files.priv_defaults_to_lib"
    test "priv/plts is :generated (priv_plts_is_generated)" do
      assert PolicyFiles.classify("priv/plts/dialyzer.plt") == :generated
    end
  end

  describe "classify/1 common paths" do
    @tag spec: "specled.policy_files.classify_kinds"
    test "lib/, skills/, and mix.exs are :lib" do
      assert PolicyFiles.classify("lib/specled_ex.ex") == :lib
      assert PolicyFiles.classify("skills/demo/SKILL.md") == :lib
      assert PolicyFiles.classify("mix.exs") == :lib
    end

    @tag spec: "specled.policy_files.classify_kinds"
    test "test/ and test_support/ are :test" do
      assert PolicyFiles.classify("test/specled_ex_test.exs") == :test
      assert PolicyFiles.classify("test_support/specled_ex_case.ex") == :test
    end

    @tag spec: "specled.policy_files.classify_kinds"
    test "docs/ and guides/ and root meta files are :doc" do
      assert PolicyFiles.classify("docs/guide.md") == :doc
      assert PolicyFiles.classify("guides/intro.md") == :doc
      assert PolicyFiles.classify("README.md") == :doc
      assert PolicyFiles.classify("CHANGELOG.md") == :doc
      assert PolicyFiles.classify("AGENTS.md") == :doc
    end

    @tag spec: "specled.policy_files.classify_kinds"
    test "unrecognized paths are :unknown" do
      assert PolicyFiles.classify("weird/top/level/file.txt") == :unknown
      assert PolicyFiles.classify("Makefile") == :unknown
    end
  end

  describe "co_change_rule/1" do
    @tag spec: "specled.policy_files.co_change_rule_total"
    test "every kind returns a rule" do
      rules =
        for kind <- [:lib, :test, :doc, :generated, :unknown],
            do: PolicyFiles.co_change_rule(kind)

      assert rules == [
               {:requires_subject_touch, :error},
               :test_only_allowed,
               :doc_only_allowed,
               :ignored,
               :unknown_escalates
             ]
    end

    @tag spec: "specled.policy_files.co_change_rule_total"
    test "unknown path escalates" do
      assert PolicyFiles.classify("weird/top/level/file.txt") == :unknown
      assert PolicyFiles.co_change_rule("weird/top/level/file.txt") == :unknown_escalates
    end
  end

  describe "docs/plans exclusion" do
    @tag spec: "specled.policy_files.plan_docs_excluded"
    test "docs/plans/ classifies as :doc but co_change_rule is :ignored (docs_plans_ignored)" do
      path = "docs/plans/2026-04-21-notes.md"
      assert PolicyFiles.classify(path) == :doc
      assert PolicyFiles.co_change_rule(path) == :ignored
      refute PolicyFiles.policy_target?(path)
    end

    @tag spec: "specled.policy_files.plan_docs_excluded"
    test "normal docs path still participates" do
      path = "docs/guide.md"
      assert PolicyFiles.co_change_rule(path) == :doc_only_allowed
      assert PolicyFiles.policy_target?(path)
    end
  end

  describe "ChangeAnalysis delegation" do
    alias SpecLedEx.ChangeAnalysis

    @tag spec: "specled.policy_files.change_analysis_delegates"
    test "ChangeAnalysis.classify/1 agrees with PolicyFiles.classify/1 on representative paths" do
      paths = [
        "lib/x.ex",
        "test/x_test.exs",
        "test_support/helper.ex",
        "docs/x.md",
        "docs/plans/note.md",
        "guides/intro.md",
        "priv/repo/migrations/20260101_add.exs",
        "priv/static/app.css",
        "priv/plts/dialyzer.plt",
        "README.md",
        "CHANGELOG.md",
        "AGENTS.md",
        "mix.exs",
        "weird/top/level/file.txt"
      ]

      for path <- paths do
        assert ChangeAnalysis.classify(path) == PolicyFiles.classify(path),
               "ChangeAnalysis.classify/1 drifted from PolicyFiles for #{path}"
      end
    end

    @tag spec: "specled.policy_files.change_analysis_delegates"
    test "ChangeAnalysis.co_change_rule/1 agrees with PolicyFiles on paths and kinds" do
      for path <- [
            "lib/x.ex",
            "test/x_test.exs",
            "docs/plans/note.md",
            "priv/plts/dialyzer.plt",
            "weird/file.txt"
          ] do
        assert ChangeAnalysis.co_change_rule(path) == PolicyFiles.co_change_rule(path)
      end

      for kind <- [:lib, :test, :doc, :generated, :unknown] do
        assert ChangeAnalysis.co_change_rule(kind) == PolicyFiles.co_change_rule(kind)
      end
    end

    @tag spec: "specled.policy_files.change_analysis_delegates"
    test "ChangeAnalysis.policy_target?/1 agrees with PolicyFiles on representative paths" do
      for path <- [
            "lib/x.ex",
            "test/x_test.exs",
            "docs/plans/note.md",
            "priv/plts/dialyzer.plt",
            "README.md",
            "weird/file.txt"
          ] do
        assert ChangeAnalysis.policy_target?(path) == PolicyFiles.policy_target?(path)
      end
    end

    @tag spec: "specled.policy_files.change_analysis_delegates"
    test "ChangeAnalysis source file has no path prefix or extension checks" do
      # Defends against re-inlining. If someone reintroduces prefix checks
      # inside ChangeAnalysis (re-breaking the delegation), this fails.
      source = File.read!("lib/specled_ex/change_analysis.ex")

      # policy_target?, classify, and co_change_rule must be one-liner
      # delegations — no prefix matching, no String.starts_with? against
      # policy kinds, no ~w(lib/ test/ ...) lists, no file extension tests.
      refute source =~ ~r/@policy_prefixes\s*~w/,
             "ChangeAnalysis must not define its own policy prefix list"

      refute source =~ ~r/@policy_root_files\s*~w/,
             "ChangeAnalysis must not define its own policy root files list"

      refute source =~ ~r/String\.starts_with\?\(path,\s*"lib\//,
             "ChangeAnalysis must not do its own \"lib/\" prefix match"

      refute source =~ ~r/String\.starts_with\?\(path,\s*"priv\//,
             "ChangeAnalysis must not do its own \"priv/\" prefix match"
    end
  end
end
