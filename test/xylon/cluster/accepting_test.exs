defmodule Xylon.Cluster.AcceptingTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Accepting

  setup do
    Accepting.reset!()
    on_exit(fn -> Accepting.reset!() end)
    :ok
  end

  test "default accepting is true" do
    assert Accepting.accepting?() == true
  end

  test "set false then true" do
    assert :ok = Accepting.set(false)
    assert Accepting.accepting?() == false
    assert Accepting.accepting_on?(Node.self()) == false
    assert :ok = Accepting.set(true)
    assert Accepting.accepting?() == true
  end
end
