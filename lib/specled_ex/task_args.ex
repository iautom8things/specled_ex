defmodule SpecLedEx.TaskArgs do
  @moduledoc """
  Shared validation of `OptionParser` leftovers for spec mix tasks.

  `validate/3` returns a uniform error message naming the task, while
  `validate!/3` keeps the raising API for callers that do not need to emit
  output before rejection.
  """

  @spec validate(String.t(), [String.t()], [{String.t(), String.t() | nil}]) ::
          :ok | {:error, String.t()}
  def validate(_task, [], []), do: :ok

  def validate(task, rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    {:error, "Invalid arguments for #{task}: #{details}"}
  end

  @spec validate!(String.t(), [String.t()], [{String.t(), String.t() | nil}]) :: :ok
  def validate!(task, rest, invalid) do
    case validate(task, rest, invalid) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
