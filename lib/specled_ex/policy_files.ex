defmodule SpecLedEx.PolicyFiles do
  @moduledoc """
  File-kind classification and co-change rule map for branch-guard.

  Gives `BranchCheck` a single place to ask two questions about a changed
  repo-relative path:

    1. What kind of file is this? (`classify/1`) — `:lib`, `:test`, `:doc`,
       `:generated`, or `:unknown`. The mapping is total; no path returns
       `nil`.
    2. What co-change rule applies? (`co_change_rule/1`) — one of
       `{:requires_subject_touch, severity}`, `:test_only_allowed`,
       `:doc_only_allowed`, `:ignored`, `:unknown_escalates`.

  ## `priv/` classification

  Paths under `priv/` classify as `:lib` by default. Only `priv/plts/`
  classifies as `:generated`. This preserves co-change enforcement on
  migrations, static assets, gettext, and other behaviour-carrying content
  under `priv/`. Broadening the carve-out requires a spec + decision update.
  See `.spec/decisions/specled.decision.priv_conservative_classification.md`.

  ## `docs/plans/` exclusion

  Paths under `docs/plans/` classify as `:doc` but are deliberately
  `:ignored` by `co_change_rule/1` — they are branch-local scratch and must
  not trigger co-change findings.
  """

  @type kind :: :lib | :test | :doc | :generated | :unknown
  @type severity :: :off | :info | :warning | :error
  @type co_change_rule ::
          {:requires_subject_touch, severity()}
          | :test_only_allowed
          | :doc_only_allowed
          | :ignored
          | :unknown_escalates

  @test_prefixes ~w(test/ test_support/)
  @doc_prefixes ~w(docs/ guides/)
  @doc_root_files ~w(README.md AGENTS.md CHANGELOG.md)
  @lib_prefixes ~w(lib/ skills/)
  @lib_root_files ~w(mix.exs)
  @plan_doc_prefix "docs/plans/"

  @doc "Classifies a repo-relative path into a file kind."
  @spec classify(String.t()) :: kind()
  def classify(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "priv/plts/") -> :generated
      String.starts_with?(path, "priv/") -> :lib
      starts_with_any?(path, @test_prefixes) -> :test
      starts_with_any?(path, @doc_prefixes) -> :doc
      path in @doc_root_files -> :doc
      starts_with_any?(path, @lib_prefixes) -> :lib
      path in @lib_root_files -> :lib
      true -> :unknown
    end
  end

  @doc """
  Returns the co-change rule that applies to a kind or path.

  Branch-local `docs/plans/` paths short-circuit to `:ignored` regardless of
  their `:doc` classification.
  """
  @spec co_change_rule(kind() | String.t()) :: co_change_rule()
  def co_change_rule(path) when is_binary(path) do
    cond do
      String.starts_with?(path, @plan_doc_prefix) -> :ignored
      true -> co_change_rule(classify(path))
    end
  end

  def co_change_rule(:lib), do: {:requires_subject_touch, :error}
  def co_change_rule(:test), do: :test_only_allowed
  def co_change_rule(:doc), do: :doc_only_allowed
  def co_change_rule(:generated), do: :ignored
  def co_change_rule(:unknown), do: :unknown_escalates

  @doc """
  Returns true when a path participates in co-change gating.

  Paths with rule `:ignored` (generated, or branch-local `docs/plans/`) are
  excluded. Paths with rule `:unknown_escalates` are also excluded from the
  gate itself; callers that want to surface unknowns can do so via a separate
  finding using `co_change_rule/1` directly.
  """
  @spec policy_target?(String.t()) :: boolean()
  def policy_target?(path) when is_binary(path) do
    case co_change_rule(path) do
      :ignored -> false
      :unknown_escalates -> false
      _ -> true
    end
  end

  defp starts_with_any?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))
end
