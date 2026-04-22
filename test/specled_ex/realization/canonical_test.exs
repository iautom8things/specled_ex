defmodule SpecLedEx.Realization.CanonicalTest do
  use ExUnit.Case, async: true

  alias SpecLedEx.Realization.Canonical

  describe "normalize/1 + hash/1" do
    test "cosmetic refactor (whitespace + variable rename) produces byte-equal hash" do
      v1 = Code.string_to_quoted!("def f(a, b), do: a + b")

      v2 =
        Code.string_to_quoted!("""
        def f(x,
              y),
          do: x + y
        """)

      assert Canonical.hash(Canonical.normalize(v1)) ==
               Canonical.hash(Canonical.normalize(v2))
    end

    test "arity change breaks the hash" do
      v1 = Code.string_to_quoted!("def f(a, b), do: a + b")
      v2 = Code.string_to_quoted!("def f(a, b, c), do: a + b + c")

      refute Canonical.hash(Canonical.normalize(v1)) ==
               Canonical.hash(Canonical.normalize(v2))
    end

    test "reserved identifiers are preserved verbatim" do
      ast = Code.string_to_quoted!("def f(), do: {__MODULE__, __CALLER__}")
      normalized = Canonical.normalize(ast)
      inspected = inspect(normalized)

      assert String.contains?(inspected, "__MODULE__")
      assert String.contains?(inspected, "__CALLER__")
    end

    test "reserved list exports the documented atoms" do
      assert :__MODULE__ in Canonical.reserved_identifiers()
      assert :__CALLER__ in Canonical.reserved_identifiers()
      assert :__ENV__ in Canonical.reserved_identifiers()
      assert :__DIR__ in Canonical.reserved_identifiers()
      assert :__STACKTRACE__ in Canonical.reserved_identifiers()
      assert :__block__ in Canonical.reserved_identifiers()
    end

    test "hash bytes are stable across repeated runs" do
      ast = Code.string_to_quoted!("def f(a), do: {:ok, a}")
      normalized = Canonical.normalize(ast)

      hashes = for _ <- 1..5, do: Canonical.hash(normalized)
      assert length(Enum.uniq(hashes)) == 1
    end

    test "deterministic serialization uses minor_version: 2" do
      # Probe the documented option set by re-serializing the normalized AST.
      ast = Code.string_to_quoted!("def f(a), do: a")
      normalized = Canonical.normalize(ast)

      direct_bytes =
        :erlang.term_to_binary(normalized, [:deterministic, minor_version: 2])

      # Matching hash implies matching byte sequence.
      assert :crypto.hash(:sha256, direct_bytes) == Canonical.hash(normalized)
    end
  end
end
