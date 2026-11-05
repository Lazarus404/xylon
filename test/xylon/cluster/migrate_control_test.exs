defmodule Xylon.Cluster.MigrateControlTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Migrate
  alias Xylon.Cluster.Presence

  setup do
    Presence.init!()
    Presence.reset!()
    Migrate.unsubscribe(self())
    :ok = Migrate.subscribe(self())
    on_exit(fn -> Migrate.unsubscribe(self()) end)
    :ok
  end

  test "on_peer_hub_down clears cohost and notifies migrate_required" do
    key = {"t1", "room-down"}
    dead = :dead_hub@host
    assert :ok = Presence.put_cohost(key, "eu-central-1", dead)
    assert :ok = Presence.put_cohost(key, "us-west-2", Node.self())

    assert :ok = Migrate.on_peer_hub_down(dead)

    cohosts = Presence.cohosts(key)
    refute Enum.any?(cohosts, &(&1.hub_node == dead))
    assert Enum.any?(cohosts, &(&1.hub_node == Node.self()))

    assert_receive %{
                     type: :migrate_required,
                     session_key: ^key,
                     reason: :edge_down,
                     target: %{node: _, region_id: _}
                   },
                   500
  end

  test "on_hub_changed no-op when unchanged" do
    assert :ok = Migrate.on_hub_changed(:a@host, :a@host)
    refute_receive %{type: :migrate_required}, 50
  end

  test "clear_home_node on edge down" do
    key = {"t1", "solo"}
    dead = :gone@host
    assert :ok = Presence.put_home(key, dead)
    assert :ok = Migrate.on_peer_hub_down(dead)
    assert Presence.home(key) == nil
  end
end
