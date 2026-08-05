defmodule SpecLedEx.Schema.Verification do
  @moduledoc false

  # Leaf module: consumed at compile time by sibling schema definitions, so
  # it must not depend on any other project module (Zoi is external).

  @kinds ~w(command tagged_tests file source_file test_file guide_file readme_file workflow_file test doc workflow contract)

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum(@kinds),
              target: Zoi.string() |> Zoi.default(""),
              covers: Zoi.list(Zoi.string()),
              execute: Zoi.boolean() |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Verification"
  def schema, do: @schema

  def kinds, do: @kinds
end
