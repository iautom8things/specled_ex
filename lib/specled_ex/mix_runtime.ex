defmodule SpecLedEx.MixRuntime do
  @moduledoc false
  @apps [:yaml_elixir, :jason]

  def ensure_started! do
    Enum.each(@apps, fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)
  end
end
