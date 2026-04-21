defmodule SpecLedEx.BranchCheck.SeverityTest do
  use SpecLedEx.Case

  import ExUnit.CaptureLog

  alias SpecLedEx.BranchCheck.Severity

  describe "resolve/3 precedence" do
    @tag spec: "specled.severity.resolve_precedence"
    test "trailer override beats config which beats default" do
      assert Severity.resolve(
               "branch_guard_realization_drift",
               [
                 config_severities: %{"branch_guard_realization_drift" => :warning},
                 trailer_override: %{"branch_guard_realization_drift" => :error}
               ],
               :info
             ) == :error
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "config beats default when no trailer override is present" do
      assert Severity.resolve(
               "some_code",
               [config_severities: %{"some_code" => :error}, trailer_override: %{}],
               :warning
             ) == :error
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "per-code default wins when neither config nor trailer names the code" do
      assert Severity.resolve("some_code", [], :warning) == :warning
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "overrides only affect the codes they name" do
      opts = [
        config_severities: %{"some_code" => :error},
        trailer_override: %{"another_code" => :info}
      ]

      assert Severity.resolve("some_code", opts, :warning) == :error
      assert Severity.resolve("another_code", opts, :warning) == :info
      assert Severity.resolve("third_code", opts, :warning) == :warning
    end
  end

  describe "resolve/3 :off precedence" do
    @tag spec: "specled.severity.off_is_absorbing"
    @tag spec: "specled.severity.non_emitting"
    test ":off in config beats a trailer override (off_beats_trailer)" do
      assert Severity.resolve(
               "branch_guard_realization_drift",
               [
                 config_severities: %{"branch_guard_realization_drift" => :off},
                 trailer_override: %{"branch_guard_realization_drift" => :error}
               ],
               :warning
             ) == :off
    end

    @tag spec: "specled.severity.off_is_absorbing"
    test ":off in config survives an absent trailer" do
      assert Severity.resolve(
               "some_code",
               [config_severities: %{"some_code" => :off}],
               :warning
             ) == :off
    end
  end

  describe "resolve/3 unknown values" do
    @tag spec: "specled.severity.known_values"
    test "unknown config value falls back to per-code default and emits Logger.warning" do
      log =
        capture_log(fn ->
          assert Severity.resolve(
                   "some_code",
                   [config_severities: %{"some_code" => :shout}],
                   :warning
                 ) == :warning
        end)

      assert log =~ ":shout"
      assert log =~ "some_code"
    end

    @tag spec: "specled.severity.known_values"
    test "unknown trailer value is ignored and config value wins" do
      log =
        capture_log(fn ->
          assert Severity.resolve(
                   "some_code",
                   [
                     config_severities: %{"some_code" => :info},
                     trailer_override: %{"some_code" => :panic}
                   ],
                   :warning
                 ) == :info
        end)

      assert log =~ ":panic"
    end
  end

  describe "known_severities/0" do
    @tag spec: "specled.severity.known_values"
    test "lists exactly the known atoms" do
      assert Severity.known_severities() == [:off, :info, :warning, :error]
    end
  end
end
