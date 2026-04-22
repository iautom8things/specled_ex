defmodule SpecLedEx.Schema do
  @moduledoc false

  alias SpecLedEx.Schema.{Decision, Exception, Meta, RealizedBy, Requirement, Scenario, Verification}

  @id_pattern ~r/^[a-z0-9][a-z0-9._-]*$/

  def id do
    Zoi.string()
    |> Zoi.regex(@id_pattern,
      error: "invalid id format: must match #{inspect(Regex.source(@id_pattern))}"
    )
  end

  def meta do
    Meta.schema()
  end

  def requirement do
    Requirement.schema()
  end

  def scenario do
    Scenario.schema()
  end

  def verification do
    Verification.schema()
  end

  def exception do
    Exception.schema()
  end

  def decision do
    Decision.schema()
  end

  @doc """
  Validates a parsed block list against its schema.
  Returns `{:ok, items}` or `{:error, message}`.
  """
  def validate_block("spec-meta", data) do
    with {:ok, result} <- zoi_parse(meta(), data, "spec-meta"),
         {:ok, normalized} <- normalize_realized_by(result) do
      {:ok, normalized}
    end
  end

  def validate_block(tag, items) when is_list(items) do
    schema =
      case tag do
        "spec-requirements" -> requirement()
        "spec-scenarios" -> scenario()
        "spec-verification" -> verification()
        "spec-exceptions" -> exception()
      end

    items
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, idx}, {valid, errs} ->
      with {:ok, parsed} <- Zoi.parse(schema, item),
           {:ok, normalized} <- maybe_normalize_realized_by(tag, parsed) do
        {[normalized | valid], errs}
      else
        {:error, errors} when is_list(errors) ->
          {valid, [format_item_errors(tag, idx, errors) | errs]}

        {:error, message} when is_binary(message) ->
          {valid, ["#{tag}[#{idx}] #{message}" | errs]}
      end
    end)
    |> case do
      {valid, []} -> {:ok, Enum.reverse(valid)}
      {_valid, errs} -> {:error, errs |> Enum.reverse() |> Enum.join("; ")}
    end
  end

  defp zoi_parse(schema, data, tag) do
    case Zoi.parse(schema, data) do
      {:ok, result} -> {:ok, result}
      {:error, errors} -> {:error, format_errors(tag, errors)}
    end
  end

  defp normalize_realized_by(meta) do
    case Map.get(meta, :realized_by) do
      nil ->
        {:ok, meta}

      value ->
        case RealizedBy.validate(value) do
          {:ok, normalized} -> {:ok, Map.put(meta, :realized_by, normalized)}
          {:error, message} -> {:error, "spec-meta #{message}"}
        end
    end
  end

  defp maybe_normalize_realized_by("spec-requirements", req) do
    case Map.get(req, :realized_by) do
      nil ->
        {:ok, req}

      value ->
        case RealizedBy.validate(value) do
          {:ok, normalized} -> {:ok, Map.put(req, :realized_by, normalized)}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp maybe_normalize_realized_by(_tag, parsed), do: {:ok, parsed}

  # Silence unused-alias warnings; aliases kept for doc readability.
  _ = Meta
  _ = Requirement

  defp format_errors(tag, errors) do
    msgs = Enum.map(errors, & &1.message)
    "#{tag} validation failed: #{Enum.join(msgs, ", ")}"
  end

  defp format_item_errors(tag, idx, errors) do
    msgs = Enum.map(errors, & &1.message)
    "#{tag}[#{idx}] validation failed: #{Enum.join(msgs, ", ")}"
  end
end
