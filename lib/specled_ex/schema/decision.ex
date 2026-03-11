defmodule SpecLedEx.Schema.Decision do
  @moduledoc false

  @statuses ~w(accepted superseded)

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: SpecLedEx.Schema.id(),
              status: Zoi.enum(@statuses),
              date: Zoi.string(),
              affects: Zoi.list(Zoi.string()),
              superseded_by: SpecLedEx.Schema.id() |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
  def statuses, do: @statuses
end
