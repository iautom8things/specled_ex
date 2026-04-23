defmodule SpecLedEx.Schema.Decision do
  # covers: specled.decisions.change_type_enum specled.decisions.weakening_set
  @moduledoc false

  @statuses ~w(accepted deprecated superseded)
  @change_types ~w(deprecates weakens narrows-scope adds-exception supersedes clarifies refines)
  @weakening_types ~w(deprecates weakens narrows-scope adds-exception)

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: SpecLedEx.Schema.id(),
              status: Zoi.enum(@statuses),
              date: Zoi.string(),
              affects: Zoi.list(Zoi.string()),
              superseded_by: SpecLedEx.Schema.id() |> Zoi.optional(),
              change_type: Zoi.enum(@change_types) |> Zoi.optional(),
              reverses_what: Zoi.string() |> Zoi.optional(),
              replaces: Zoi.list(SpecLedEx.Schema.id()) |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
  def statuses, do: @statuses
  def change_types, do: @change_types
  def weakening_types, do: @weakening_types
end
