defmodule Mix.Tasks.Xylon.EchoTest do
  use ExUnit.Case, async: true

  test "mix task module defines run/1" do
    assert {:module, _} = Code.ensure_loaded(Mix.Tasks.Xylon.Echo)
    assert function_exported?(Mix.Tasks.Xylon.Echo, :run, 1)
  end
end
