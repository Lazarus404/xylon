defmodule Xylon.Cluster.PlacementTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Accepting
  alias Xylon.Cluster.Placement
  alias Xylon.Cluster.Presence

  setup do
    Presence.init!()
    Presence.reset!()
    Accepting.reset!()
    on_exit(fn -> Accepting.reset!() end)
    :ok
  end

  test "multi_home returns hub" do
    hub = :hub@host

    assert {:ok, place} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "r1",
               region_hint: "us-west-2",
               multi_home: true,
               hub_node: hub,
               nodes: [hub, :w@host],
               accepting: %{hub => true, :w@host => true},
               edge_urls: %{"us-west-2" => "https://usw2.example"}
             )

    assert place.node == hub
    assert place.role == :hub
    assert place.region_id == "us-west-2"
    assert place.edge_url == "https://usw2.example"
    assert [%{hub_node: ^hub}] = Presence.cohosts({"t1", "r1"})
  end

  test "single_home sticky on second recommend" do
    nodes = [:b@host, :a@host]

    assert {:ok, first} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "solo",
               region_hint: "eu",
               multi_home: false,
               nodes: nodes,
               hub_node: :b@host,
               accepting: %{:a@host => true, :b@host => true}
             )

    assert first.node == :a@host
    assert first.role == :worker

    assert {:ok, second} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "solo",
               region_hint: "eu",
               multi_home: false,
               nodes: nodes,
               hub_node: :b@host,
               accepting: %{:a@host => true, :b@host => true}
             )

    assert second.node == :a@host
  end

  test "skips non-accepting nodes when picking new home" do
    assert {:ok, place} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "drain-pick",
               region_hint: "eu",
               nodes: [:a@host, :b@host],
               hub_node: :a@host,
               accepting: %{:a@host => false, :b@host => true}
             )

    assert place.node == :b@host
  end

  test "sticky home on drained node is cleared and re-picked" do
    Presence.put_home({"t1", "sticky-drain"}, :a@host)

    assert {:ok, place} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "sticky-drain",
               region_hint: "eu",
               nodes: [:a@host, :b@host],
               hub_node: :a@host,
               accepting: %{:a@host => false, :b@host => true}
             )

    assert place.node == :b@host
    assert Presence.home({"t1", "sticky-drain"}) == :b@host
  end

  test "multi_home hub not accepting fails closed" do
    assert {:error, :no_accepting_nodes} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "mh-drain",
               region_hint: "eu",
               multi_home: true,
               hub_node: :hub@host,
               nodes: [:hub@host, :w@host],
               accepting: %{:hub@host => false, :w@host => true}
             )
  end

  test "empty accepting pool fails closed" do
    assert {:error, :no_accepting_nodes} =
             Placement.recommend(
               tenant_id: "t1",
               session_id: "none",
               region_hint: "eu",
               nodes: [:a@host],
               hub_node: :a@host,
               accepting: %{:a@host => false}
             )
  end
end
