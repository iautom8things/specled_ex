defmodule SpecLedEx.Evidence.Entry do
  @moduledoc """
  Canonical evidence entry payloads stored on the local `spec-evidence` ref.
  """

  alias SpecLedEx.Json

  @schema_version 1
  @filename_regex ~r/^[0-9a-f]{40,64}\.json$/

  @type t :: map()

  @doc """
  Builds an evidence entry for a verification report.
  """
  @spec build(String.t(), map(), keyword()) :: t()
  def build(tree_hash, report, opts \\ []) do
    %{
      "schema_version" => @schema_version,
      "tree_hash" => tree_hash,
      "run_at" => Keyword.get_lazy(opts, :run_at, &now/0),
      "run_id" => Keyword.get_lazy(opts, :run_id, &run_id/0),
      "specled_version" => Keyword.get_lazy(opts, :specled_version, &specled_version/0),
      "verification" => verification_outcomes(report),
      "findings" => normalized_findings(report["findings"] || [])
    }
  end

  @doc """
  Encodes an entry through the repository's canonical JSON writer.
  """
  @spec encode!(t()) :: binary()
  def encode!(entry) when is_map(entry) do
    entry
    |> Json.encode_to_iodata!()
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes and validates an entry filename and payload.
  """
  @spec decode_file(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def decode_file(filename, json) when is_binary(filename) and is_binary(json) do
    with true <- valid_filename?(filename),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json),
         true <- decoded["schema_version"] == @schema_version,
         true <- "#{decoded["tree_hash"]}.json" == filename do
      {:ok, decoded}
    else
      false -> {:error, :invalid_entry}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_entry}
    end
  end

  @doc """
  Returns the winning entry according to `(run_at, run_id)` lexicographic order.
  """
  @spec latest(t() | nil, t()) :: t()
  def latest(nil, incoming), do: incoming

  def latest(existing, incoming) when is_map(existing) and is_map(incoming) do
    if stamp(incoming) > stamp(existing), do: incoming, else: existing
  end

  @doc false
  def valid_filename?(filename), do: Regex.match?(@filename_regex, filename)

  defp verification_outcomes(report) do
    report
    |> get_in(["verification", "claims"])
    |> case do
      claims when is_list(claims) -> claims
      _ -> []
    end
    |> Enum.reduce(%{}, fn
      %{"cover_id" => cover_id} = claim, acc when is_binary(cover_id) ->
        Map.put(acc, cover_id, %{
          "strength" => claim["strength"],
          "meets_minimum" => claim["meets_minimum"] == true
        })

      _, acc ->
        acc
    end)
  end

  defp normalized_findings(findings) do
    state =
      SpecLedEx.write_state(
        %{"subjects" => [], "decisions" => [], "summary" => %{}},
        %{"findings" => findings},
        System.tmp_dir!(),
        unique_state_path()
      )

    decoded = Json.read(state)
    File.rm(state)
    decoded["findings"] || []
  end

  defp unique_state_path do
    "specled-evidence-entry-#{System.unique_integer([:positive, :monotonic])}.json"
  end

  defp stamp(entry), do: {entry["run_at"] || "", entry["run_id"] || ""}

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp run_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp specled_version do
    :spec_led_ex
    |> Application.spec(:vsn)
    |> to_string()
  end
end
