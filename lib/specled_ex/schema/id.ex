defmodule SpecLedEx.Schema.Id do
  @moduledoc false

  # Leaf module: the id schema is consumed at compile time by every
  # `Zoi.struct` definition under SpecLedEx.Schema.*, so it must not
  # depend on any other project module.

  # \A/\z, not ^/$: `$` matches before a trailing newline, so anchoring with
  # ^/$ accepts ids like "a\n". The api_boundary hash tier covers function
  # heads only and would never catch a regression of this pattern.
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]*\z/

  def id do
    Zoi.string()
    |> Zoi.regex(@id_pattern,
      error: "invalid id format: must match #{inspect(Regex.source(@id_pattern))}"
    )
  end
end
