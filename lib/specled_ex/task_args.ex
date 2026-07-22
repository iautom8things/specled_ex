defmodule SpecLedEx.TaskArgs do
  @moduledoc """
  Shared rejection of `OptionParser` leftovers for spec mix tasks: any
  unparsed argument or invalid flag raises with a uniform message naming
  the task.
  """

  @spec validate!(String.t(), [String.t()], [{String.t(), String.t() | nil}]) :: :ok
  def validate!(_task, [], []), do: :ok

  def validate!(task, rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for #{task}: #{details}")
  end
end
