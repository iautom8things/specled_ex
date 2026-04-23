defmodule SpecLedEx.ModalClassTest do
  use SpecLedEx.Case

  alias SpecLedEx.ModalClass

  describe "classify/1" do
    test "classifies strong positive modals" do
      assert ModalClass.classify("The system MUST reject invalid input.") == :must
      assert ModalClass.classify("The system SHALL validate the request.") == :shall
    end

    test "classifies strong negative modals" do
      assert ModalClass.classify("The system MUST NOT accept unsigned tokens.") == :must_not
      assert ModalClass.classify("The system SHALL NOT expose raw IDs.") == :shall_not
    end

    test "classifies weak modals" do
      assert ModalClass.classify("The system should log a warning.") == :should
      assert ModalClass.classify("The system may redact PII.") == :may
    end

    test "returns :none for statements without a modal verb" do
      assert ModalClass.classify("The system logs a warning.") == :none
      assert ModalClass.classify("") == :none
    end

    test "is case-insensitive across lower, upper, and mixed case" do
      lower = ModalClass.classify("the system must reject input")
      upper = ModalClass.classify("THE SYSTEM MUST REJECT INPUT")
      mixed = ModalClass.classify("The System MuSt Reject Input")

      assert lower == :must
      assert upper == :must
      assert mixed == :must
    end

    test "is insensitive to trailing punctuation" do
      assert ModalClass.classify("The system MUST reject X.") == :must
      assert ModalClass.classify("The system MUST reject X!") == :must
      assert ModalClass.classify("The system MUST reject X?") == :must
    end

    test "negative forms take precedence over positive forms" do
      assert ModalClass.classify("The system MUST NOT do X but must log.") == :must_not
      assert ModalClass.classify("The system SHALL NOT expose and must encrypt.") == :shall_not
    end

    test "is deterministic across repeated invocations" do
      for statement <- [
            "The system MUST reject X.",
            "The system should log.",
            "The system MAY cache.",
            "The system SHALL NOT leak."
          ] do
        first = ModalClass.classify(statement)
        second = ModalClass.classify(statement)
        third = ModalClass.classify(statement)
        assert first == second
        assert second == third
      end
    end

    test "returns an atom in the declared modal set for every input" do
      samples = [
        "",
        "random text with no modal",
        "The system MUST do X.",
        "The system must not do X.",
        "The system SHALL do X.",
        "The system shan't do X.",
        "The system should do X.",
        "The system may do X.",
        "contraction: mustn't matters"
      ]

      for sample <- samples do
        result = ModalClass.classify(sample)
        assert result in ModalClass.modals()
      end
    end
  end

  describe "downgrade?/2" do
    test "returns false for identity pairs over the full modal set" do
      for m <- ModalClass.modals() do
        refute ModalClass.downgrade?(m, m), "identity for #{inspect(m)} should not be downgrade"
      end
    end

    test "within-polarity weakening is a downgrade" do
      assert ModalClass.downgrade?(:must, :shall)
      assert ModalClass.downgrade?(:must, :should)
      assert ModalClass.downgrade?(:must, :may)
      assert ModalClass.downgrade?(:must, :none)
      assert ModalClass.downgrade?(:shall, :should)
      assert ModalClass.downgrade?(:should, :may)
      assert ModalClass.downgrade?(:must_not, :shall_not)
    end

    test "within-polarity strengthening is not a downgrade" do
      refute ModalClass.downgrade?(:shall, :must)
      refute ModalClass.downgrade?(:should, :must)
      refute ModalClass.downgrade?(:may, :should)
      refute ModalClass.downgrade?(:shall_not, :must_not)
    end

    test "clean polarity flips negative->positive are not downgrades" do
      refute ModalClass.downgrade?(:must_not, :must)
      refute ModalClass.downgrade?(:shall_not, :shall)
    end

    test "positive to negative cross-polarity is a downgrade" do
      assert ModalClass.downgrade?(:must, :must_not)
      assert ModalClass.downgrade?(:shall, :shall_not)
      assert ModalClass.downgrade?(:must, :shall_not)
      assert ModalClass.downgrade?(:shall, :must_not)
    end

    test "negative to positive cross-polarity is never a downgrade" do
      refute ModalClass.downgrade?(:must_not, :shall)
      refute ModalClass.downgrade?(:shall_not, :must)
      refute ModalClass.downgrade?(:must_not, :should)
      refute ModalClass.downgrade?(:must_not, :may)
    end

    test "transitions ending at :none are downgrades from any non-:none modal" do
      assert ModalClass.downgrade?(:must, :none)
      assert ModalClass.downgrade?(:shall, :none)
      assert ModalClass.downgrade?(:must_not, :none)
      assert ModalClass.downgrade?(:shall_not, :none)
      assert ModalClass.downgrade?(:should, :none)
      assert ModalClass.downgrade?(:may, :none)
    end

    test "transitions starting from :none are never downgrades" do
      for m <- ModalClass.modals() do
        refute ModalClass.downgrade?(:none, m)
      end
    end

    test "is total over the 7 x 7 Cartesian product without raising" do
      for prior <- ModalClass.modals(), current <- ModalClass.modals() do
        result = ModalClass.downgrade?(prior, current)
        assert is_boolean(result),
               "downgrade?(#{inspect(prior)}, #{inspect(current)}) returned #{inspect(result)}"
      end
    end

    test "is monotonic: if a->b and b->c are downgrades, so is a->c" do
      modals = ModalClass.modals()

      for a <- modals, b <- modals, c <- modals do
        if ModalClass.downgrade?(a, b) and ModalClass.downgrade?(b, c) do
          assert ModalClass.downgrade?(a, c),
                 "transitivity failed for #{inspect({a, b, c})}"
        end
      end
    end
  end
end
