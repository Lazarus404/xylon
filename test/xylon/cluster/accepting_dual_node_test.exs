defmodule Xylon.Cluster.AcceptingDualNodeTest do
  use ExUnit.Case, async: false

  @moduletag :dual_node

  alias Xylon.Cluster.Accepting
  alias Xylon.Cluster.Placement
  alias Xylon.Cluster.Presence

  test "drain peer: place lands on self; create on peer fails closed" do
    case Xylon.Trunk.Lab.start_pair() do
      {:ok, %{a: node_a, b: node_b, stop: stop}} ->
        on_exit(fn ->
          Accepting.reset!()
          :erpc.call(node_b, Accepting, :reset!, [])
          stop.()
        end)

        Accepting.reset!()
        :ok = :erpc.call(node_b, Accepting, :reset!, [])
        Presence.reset!()
        :ok = :erpc.call(node_b, Presence, :reset!, [])

        assert node_a == Node.self()
        assert :ok = :erpc.call(node_b, Accepting, :set, [false])
        refute :erpc.call(node_b, Accepting, :accepting?, [])

        assert {:ok, place} =
                 Placement.recommend(
                   tenant_id: "t1",
                   session_id: "dual-drain-#{System.unique_integer([:positive])}",
                   region_hint: "eu",
                   nodes: [node_a, node_b]
                 )

        assert place.node == node_a

        assert {:error, :not_accepting} =
                 :erpc.call(node_b, Xylon.Session, :create, [
                   "t1",
                   "peer-new-#{System.unique_integer([:positive])}",
                   :echo,
                   []
                 ])

      {:error, reason} ->
        flunk("dual-node start failed: #{inspect(reason)}")
    end
  end
end
