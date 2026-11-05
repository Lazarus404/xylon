defmodule Xylon.Cluster.PresenceTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Presence

  setup do
    Presence.init!()
    Presence.reset!()
    :ok
  end

  test "put and list cohosts" do
    key = {"t1", "room1"}
    assert :ok = Presence.put_cohost(key, "us-west-2", :hub_a@host)
    assert :ok = Presence.put_cohost(key, "eu-central-1", :hub_b@host)

    cohosts = Presence.cohosts(key)
    assert length(cohosts) == 2
    assert Enum.find(cohosts, &(&1.region_id == "us-west-2")).hub_node == :hub_a@host
    assert Enum.find(cohosts, &(&1.region_id == "eu-central-1")).hub_node == :hub_b@host
  end

  test "put_cohost replaces hub for same region" do
    key = {"t1", "room2"}
    assert :ok = Presence.put_cohost(key, "us-west-2", :old@host)
    assert :ok = Presence.put_cohost(key, "us-west-2", :new@host)
    assert [%{region_id: "us-west-2", hub_node: :new@host}] = Presence.cohosts(key)
  end

  test "single-home sticky" do
    key = {"t1", "solo"}
    assert Presence.home(key) == nil
    assert :ok = Presence.put_home(key, :worker@host)
    assert Presence.home(key) == :worker@host
  end
end
