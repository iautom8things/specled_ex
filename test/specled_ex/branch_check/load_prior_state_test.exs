defmodule SpecLedEx.BranchCheck.LoadPriorStateTest do
  # covers: specled.branch_guard.subject_cochange specled.append_only.no_baseline
  use ExUnit.Case, async: true

  alias SpecLedEx.BranchCheck

  describe "classify_load_error/1" do
    test "missing-file-at-base resolves to :first_run" do
      # Canonical git output when the commit resolves but the path is absent
      # at that commit (the typical bootstrap case — base ref exists, but
      # .spec/state.json has not yet been committed).
      output = "fatal: path '.spec/state.json' does not exist in 'abc1234'\n"
      assert BranchCheck.classify_load_error(output) == :first_run
    end

    test "shallow-clone resolves to :shallow_clone" do
      # Canonical git output when the object referenced is unreachable in the
      # fetched history (shallow clone): the ref name resolved into a SHA but
      # the SHA is not present in the object database.
      output = "fatal: bad object 0123456789abcdef0123456789abcdef01234567\n"
      assert BranchCheck.classify_load_error(output) == :shallow_clone
    end

    test "bad-ref resolves to :bad_ref" do
      # Canonical git output when the ref itself does not exist (typo, or a
      # branch that was never fetched locally).
      output =
        "fatal: ambiguous argument 'not-a-ref': unknown revision or path not in the working tree.\n"

      assert BranchCheck.classify_load_error(output) == :bad_ref
    end
  end
end
