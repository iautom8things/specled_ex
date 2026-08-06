defmodule SpecLedEx.EmitterCodes do
  @moduledoc false

  # Emitter-derived code sets, scraped from lib/ source, used so the
  # hand-maintained catalogs (governance-row codes list, severity table)
  # cannot go stale against the emitters.
  #
  # Deliberately narrower than docs_identifier_lint_test's
  # implementation_guarded_codes/0, which scans a curated multi-file list with
  # a broader pattern. This helper reads the one module that emits the family
  # and matches only literal `code: "..."` keys — a new code emitted from a
  # different module, or built without a literal `code:` key, is invisible
  # here; the docs-lint corpus scan is the gate for that case.

  @append_only_source "lib/specled_ex/append_only.ex"

  def append_only_codes do
    source = File.read!(@append_only_source)

    ~r/code:\s*"(append_only\/[a-z0-9_]+)"/
    |> Regex.scan(source)
    |> Enum.map(fn [_full, code] -> code end)
    |> MapSet.new()
  end
end
