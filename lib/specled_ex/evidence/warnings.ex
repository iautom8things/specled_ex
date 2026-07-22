defmodule SpecLedEx.Evidence.Warnings do
  @moduledoc """
  Single emission point for evidence warning maps (`%{code:, message:}`)
  surfaced by mix tasks, so `spec.sync`, `spec.prune`, and `spec.check`
  print them identically instead of drifting apart.
  """

  @type warning :: %{code: String.t(), message: String.t()}

  @spec emit(warning() | [warning()]) :: :ok
  def emit(warnings) when is_list(warnings), do: Enum.each(warnings, &emit/1)
  def emit(%{message: message}), do: Mix.shell().error(message)
end
