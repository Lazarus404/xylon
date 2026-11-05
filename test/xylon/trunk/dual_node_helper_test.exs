defmodule Xylon.Trunk.DualNodeHelperTest do
  use ExUnit.Case, async: false

  @moduletag :dual_node

  test "start_pair returns two connected nodes" do
    case Xylon.Trunk.Lab.start_pair() do
      {:ok, %{a: node_a, b: node_b, stop: stop}} ->
        on_exit(stop)
        assert node_a == Node.self()
        assert :erpc.call(node_b, Node, :self, []) == node_b
        assert node_b in Node.list() or Node.connect(node_b)

      {:error, reason} ->
        flunk("dual-node start failed: #{inspect(reason)}")
    end
  end
end
