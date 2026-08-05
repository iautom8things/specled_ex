defmodule SpecLedEx.Schema.Id do
  @moduledoc false

  # Leaf module: the id schema is consumed at compile time by every
  # `Zoi.struct` definition under SpecLedEx.Schema.*, so it must not
  # depend on any other project module.

  @id_pattern ~r/^[a-z0-9][a-z0-9._-]*$/

  def id do
    Zoi.string()
    |> Zoi.regex(@id_pattern,
      error: "invalid id format: must match #{inspect(Regex.source(@id_pattern))}"
    )
  end
end
