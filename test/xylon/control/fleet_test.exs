defmodule Xylon.Control.FleetTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Accepting
  alias Xylon.Cluster.Presence
  alias Xylon.Control.Fleet
  alias Xylon.Control.Membership

  setup do
    Xylon.Catalogue.reset!()
    Presence.reset!()
    Accepting.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    start_supervised!(Membership)
    on_exit(fn -> Accepting.reset!() end)
    :ok
  end

  test "local_node_snapshot counts tenant sessions and participants" do
    sid = "fleet-local-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})

    snap = Fleet.local_node_snapshot("t1")
    assert snap["session_count"] >= 1
    assert snap["participant_count"] >= 2
    assert snap["node"] == Atom.to_string(Node.self())
    assert is_binary(snap["region"]) and snap["region"] != ""
    assert snap["reachable"] == true
    assert snap["accepting"] == true
    assert is_integer(snap["cohost_hub_count"])

    other = Fleet.local_node_snapshot("other-tenant")
    assert other["session_count"] == 0
    assert other["participant_count"] == 0

    GenServer.stop(session)
  end

  test "local_node_snapshot cohost_hub_count when this node is a cohost hub" do
    Presence.put_cohost({"t1", "room-co"}, "eu-west", Node.self())
    snap = Fleet.local_node_snapshot("t1")
    assert snap["cohost_hub_count"] >= 1
  end

  test "collect_nodes includes self" do
    nodes = Fleet.collect_nodes("t1")
    assert Enum.any?(nodes, &(&1["node"] == Atom.to_string(Node.self())))
    assert Enum.all?(nodes, &(&1["reachable"] == true))
  end

  test "summary_from_nodes merges synthetic dual-node snapshots" do
    nodes = [
      %{
        "node" => "a@host",
        "region" => "eu-west",
        "session_count" => 1,
        "participant_count" => 2,
        "hub" => true,
        "cohost_hub_count" => 0,
        "reachable" => true
      },
      %{
        "node" => "b@host",
        "region" => "eu-west",
        "session_count" => 1,
        "participant_count" => 1,
        "hub" => false,
        "cohost_hub_count" => 1,
        "reachable" => true
      }
    ]

    summary = Fleet.summary_from_nodes(nodes)
    assert summary["regions"] == ["eu-west"]
    assert summary["node_count"] == 2
    assert summary["healthy_count"] == 2
    assert summary["unhealthy_count"] == 0
    assert summary["session_count"] == 2
    assert summary["participant_count"] == 3
    assert summary["hub_node"] == "a@host"
    assert is_boolean(summary["connected"])
    refute Map.has_key?(summary, "media")
    refute Enum.any?(nodes, &Map.has_key?(&1, "sdp"))
  end

  test "local_node_snapshot reflects Accepting.set false" do
    assert :ok = Accepting.set(false)
    snap = Fleet.local_node_snapshot("t1")
    assert snap["accepting"] == false
  end

  test "summary_from_nodes counts unreachable as unhealthy" do
    nodes = [
      %{
        "node" => "a@host",
        "region" => "eu-west",
        "session_count" => 1,
        "participant_count" => 1,
        "hub" => true,
        "reachable" => true
      },
      %{
        "node" => "b@host",
        "region" => "eu-west",
        "session_count" => 0,
        "participant_count" => 0,
        "hub" => false,
        "reachable" => false
      }
    ]

    summary = Fleet.summary_from_nodes(nodes)
    assert summary["healthy_count"] == 1
    assert summary["unhealthy_count"] == 1
  end
end
