defmodule SpecLedEx.Realization.Use do
  # covers: specled.use_tier.enumerate_consumers
  # covers: specled.use_tier.provider_hash_composes
  # covers: specled.use_tier.scenario.consumers_current_not_persisted
  @moduledoc """
  Fifth realization tier. Tracks consumers of macro providers (modules with
  `__using__/1`) by walking the compiler tracer's MFA edge manifest, then
  collapses per-consumer drift to a single root-cause finding via
  `SpecLedEx.Realization.Drift.dedupe/2`.

  `consumers_for/2` reads the tracer manifest each invocation — the consumer
  list is **not** persisted in `state.json`. This keeps the consumer set
  always-current so that adding or removing a consumer on a branch is
  reflected in the next `mix spec.check` without a state-write step (per
  `specled.use_tier.enumerate_consumers`).

  `hash/2` composes the use-tier hash from the provider's `expanded_behavior`
  hash for `__using__/1` plus the sorted consumer module list. The use-tier
  hash drifts when the provider's macro body changes OR when the set of
  consumers changes.

  `run/3` emits drift deltas in a shape that `Drift.dedupe/2` recognizes as a
  macro-provider root cause.
  """

  alias SpecLedEx.Compiler.Tracer
  alias SpecLedEx.Realization.{Binding, Canonical, ExpandedBehavior, HashStore}

  @tier "use"
  @drift_code "branch_guard_realization_drift"
  @dangling_code "branch_guard_dangling_binding"
  @detector_unavailable_code "detector_unavailable"

  @type binding_ref :: %{
          subject_id: String.t(),
          requirement_id: String.t() | nil,
          mfa: String.t()
        }

  @type hash_result ::
          {:ok, binary()}
          | {:error, {:debug_info_stripped, module()}}
          | {:error, {:not_found, map()}}

  @doc """
  Returns the sorted list of consumer modules that `use Provider` (i.e. that
  invoke `Provider.__using__/1` at compile time).

  Consults the compiler tracer's ETF edge manifest. The list is recomputed on
  every call — never persisted — so a freshly-added consumer is visible
  immediately after compile.

  Options:
    * `:tracer_edges` — pre-loaded `%{caller_mfa => [callee_mfa]}` map (test seam).
    * `:tracer_manifest` — explicit ETF path; defaults to `Tracer.manifest_path/0`.
  """
  @spec consumers_for(module(), keyword()) :: [module()]
  def consumers_for(provider, opts \\ []) when is_atom(provider) do
    edges = load_edges(opts)

    edges
    |> Enum.flat_map(fn {{caller_mod, _f, _a}, callees} ->
      if caller_mod != provider and Enum.any?(callees, &using_call?(&1, provider)),
        do: [caller_mod],
        else: []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Hashes the use-tier composition for a provider module string.

  Composes:
    * the provider's `expanded_behavior` hash for `__using__/1`,
    * plus the sorted consumer module list (recomputed via `consumers_for/2`).

  Returns `{:error, {:not_found, _}}` when the provider does not export
  `__using__/1`. Bubbles up `{:error, {:debug_info_stripped, mod}}` from the
  expanded_behavior tier when the provider's beam was compiled without
  `debug_info`.
  """
  @spec hash(String.t(), keyword()) :: hash_result()
  def hash(provider_module_string, opts \\ []) when is_binary(provider_module_string) do
    with {:ok, provider_mod} <- parse_module(provider_module_string),
         {:ok, provider_hash} <-
           ExpandedBehavior.hash("#{provider_module_string}.__using__/1") do
      consumers = consumers_for(provider_mod, opts)
      composed = Canonical.hash({:__use__, provider_module_string, provider_hash, consumers})
      {:ok, composed}
    else
      {:error, {:debug_info_stripped, mod}} ->
        {:error, {:debug_info_stripped, mod}}

      {:error, {:not_found, details}} ->
        {:error, {:not_found, details}}

      {:error, :invalid_module} ->
        {:error,
         {:not_found, %{module: provider_module_string, reason: :invalid_module}}}
    end
  end

  @doc """
  Runs the use tier for a list of provider bindings.

  Each binding's `:mfa` field is interpreted as a provider module name (no
  function/arity suffix). Emits `branch_guard_realization_drift` deltas on
  hash mismatch with extra fields that the dedupe layer recognizes as a root
  cause:

    * `:tier` — `:use`
    * `:provider` — provider module atom
    * `:provider_mfa` — `{provider_mod, :__using__, 1}` tuple
    * `:hash_prefix_before` / `:hash_prefix_after` — 8-char hex prefixes
    * `:consumers` — sorted consumer modules

  Opts:
    * `:umbrella?` — when true, emits a single `detector_unavailable` finding.
    * `:root` — project root for HashStore read.
    * `:tracer_edges` / `:tracer_manifest` — forwarded to `consumers_for/2`.
  """
  @spec run([binding_ref()], term(), keyword()) :: [map()]
  def run(bindings, context \\ nil, opts \\ []) do
    cond do
      Keyword.get(opts, :umbrella?, false) ->
        [
          %{
            "code" => @detector_unavailable_code,
            "reason" => "umbrella_unsupported",
            "message" =>
              "use tier does not support umbrella apps in v1. " <>
                "Re-run per umbrella child app or wait for v1.1."
          }
        ]

      true ->
        root = Keyword.get(opts, :root, File.cwd!())
        store = HashStore.read(root)

        {findings, _reported} =
          Enum.reduce(bindings, {[], MapSet.new()}, fn binding, {acc, reported} ->
            {bfindings, reported} = check_binding(binding, context, store, opts, reported)
            {acc ++ bfindings, reported}
          end)

        findings
    end
  end

  defp check_binding(%{mfa: provider_string} = binding, _context, store, opts, reported) do
    case hash(provider_string, opts) do
      {:ok, current} ->
        case HashStore.fetch(store, @tier, provider_string) do
          nil ->
            {[], reported}

          committed when committed == current ->
            {[], reported}

          committed ->
            {[drift_finding(binding, provider_string, committed, current, opts)], reported}
        end

      {:error, {:debug_info_stripped, mod}} ->
        if MapSet.member?(reported, mod) do
          {[], reported}
        else
          {[detector_unavailable_finding(binding, mod)], MapSet.put(reported, mod)}
        end

      {:error, {:not_found, details}} ->
        {[dangling_finding(binding, details)], reported}
    end
  end

  defp drift_finding(binding, provider_string, committed, current, opts) do
    {:ok, provider_mod} = parse_module(provider_string)
    consumers = consumers_for(provider_mod, opts)

    %{
      subject_id: binding.subject_id,
      requirement_id: Map.get(binding, :requirement_id),
      code: @drift_code,
      tier: :use,
      mfa: provider_string,
      provider: provider_mod,
      provider_mfa: {provider_mod, :__using__, 1},
      hash_prefix_before: hex_prefix(committed),
      hash_prefix_after: hex_prefix(current),
      consumers: consumers,
      message:
        "use-tier hash for provider #{inspect(provider_mod)} differs from committed value " <>
          "(subject=#{binding.subject_id}, consumers_affected=#{length(consumers)})"
    }
  end

  defp dangling_finding(binding, details) do
    %{
      "code" => @dangling_code,
      "tier" => @tier,
      "subject_id" => binding.subject_id,
      "requirement_id" => Map.get(binding, :requirement_id),
      "mfa" => binding.mfa,
      "message" =>
        "Declared use binding #{binding.mfa} is not defined " <>
          "(subject=#{binding.subject_id}, tier=#{@tier}). " <>
          "Update realized_by or restore the provider. " <>
          "Searched: #{inspect(Map.get(details, :searched, [:beam]))}"
    }
  end

  defp detector_unavailable_finding(binding, mod) do
    %{
      "code" => @detector_unavailable_code,
      "reason" => "debug_info_stripped",
      "tier" => @tier,
      "subject_id" => binding.subject_id,
      "module" => inspect(mod),
      "message" =>
        "use tier cannot hash #{inspect(mod)}: beam has no debug_info " <>
          "(likely @compile {:no_debug_info, true}). Subject not considered drifted on this tier."
    }
  end

  defp hex_prefix(hash_bin) when is_binary(hash_bin) do
    hash_bin
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp using_call?({mod, :__using__, _arity}, provider) when mod == provider, do: true
  defp using_call?(_, _), do: false

  defp parse_module(module_string) do
    case Binding.parse(module_string) do
      {:ok, {:module, mod}} -> {:ok, mod}
      {:ok, {mod, _f, _a}} -> {:ok, mod}
      {:error, :invalid_mfa, _} -> {:error, :invalid_module}
    end
  end

  defp load_edges(opts) do
    case Keyword.get(opts, :tracer_edges) do
      edges when is_map(edges) ->
        edges

      _ ->
        path = Keyword.get(opts, :tracer_manifest, Tracer.manifest_path())
        read_tracer_etf(path)
    end
  end

  defp read_tracer_etf(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary) do
            map when is_map(map) -> map
            _ -> %{}
          end
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
