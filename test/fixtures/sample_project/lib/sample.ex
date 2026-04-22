defmodule Sample do
  @moduledoc "Tiny module exercised by the compile-manifest integration test."

  def hello, do: :world

  def greet(name), do: "hello #{name}"
end
