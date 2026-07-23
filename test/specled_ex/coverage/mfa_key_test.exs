defmodule SpecLedEx.Coverage.MfaKeyTest do
  use ExUnit.Case, async: true

  @moduletag spec: ["specled.coverage_capture.mfa_key_round_trip"]

  alias SpecLedEx.Coverage.MfaKey

  describe "format/1" do
    test "formats a module/function/arity triple as Mod.fun/arity" do
      assert MfaKey.format({SpecLedEx.Coverage.Store, :write_v2, 2}) ==
               "SpecLedEx.Coverage.Store.write_v2/2"
    end

    test "formats a zero-arity function" do
      assert MfaKey.format({SpecLedEx.Coverage.Store, :default_path, 0}) ==
               "SpecLedEx.Coverage.Store.default_path/0"
    end
  end

  describe "parse/1" do
    test "parses a well-formed Mod.fun/arity string" do
      assert MfaKey.parse("SpecLedEx.Coverage.Store.write_v2/2") ==
               {:ok, {SpecLedEx.Coverage.Store, :write_v2, 2}}
    end

    test "returns an error for a missing arity" do
      assert MfaKey.parse("SpecLedEx.Coverage.Store.write_v2") == {:error, :invalid_mfa_key}
    end

    test "returns an error for a non-integer arity" do
      assert MfaKey.parse("SpecLedEx.Coverage.Store.write_v2/two") ==
               {:error, :invalid_mfa_key}
    end

    test "returns an error when the module segment is not a valid alias" do
      assert MfaKey.parse("coverage.store.write_v2/2") == {:error, :invalid_mfa_key}
    end

    test "returns an error for a bare atom with no module segment" do
      assert MfaKey.parse("write_v2/2") == {:error, :invalid_mfa_key}
    end

    test "returns an error for garbage input" do
      assert MfaKey.parse("not an mfa key at all") == {:error, :invalid_mfa_key}
      assert MfaKey.parse("") == {:error, :invalid_mfa_key}
    end
  end

  describe "mfa_key_format_parse_round_trip scenario" do
    test "format/1 then parse/1 returns the original triple" do
      for mfa <- [
            {SpecLedEx.Coverage.Store, :write_v2, 2},
            {SpecLedEx.Coverage.Aggregate, :ingest, 2},
            {Elixir.Covered, :add, 2},
            {SpecLedEx.Coverage.Store, :default_path, 0}
          ] do
        assert MfaKey.parse(MfaKey.format(mfa)) == {:ok, mfa}
      end
    end
  end
end
