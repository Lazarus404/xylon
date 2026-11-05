defmodule Xylon.Cluster.MigrateHubWireTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.{Hub, Migrate, Presence}

  setup do
    Presence.init!()
    Presence.reset!()

    Application.put_env(:xylon, :cluster,
      enabled: true,
      region_id: "test-region",
      hub_priority: 0,
      topologies: []
    )

    case Process.whereis(Hub) do
      nil -> {:ok, _} = start_supervised(Hub)
      _ -> :ok
    end

    :ok = Hub.set_membership_override([{Node.self(), 0}])
    :ok = Hub.reelect()
    :ok = Migrate.subscribe(self())
    on_exit(fn -> Migrate.unsubscribe(self()) end)
    :ok
  end

  test "hub change notifies when this node becomes hub" do
    remote = :other@host
    key = {"t1", "hub-wire"}
    assert :ok = Presence.put_cohost(key, "test-region", remote)

    assert :ok = Hub.set_membership_override([{Node.self(), 0}, {remote, 9}])
    assert :ok = Hub.reelect()
    refute Hub.hub?()

    assert :ok = Hub.set_membership_override([{Node.self(), 5}])
    assert :ok = Hub.reelect()
    assert Hub.hub?()

    assert_receive %{type: :migrate_required, reason: :hub_changed}, 500
  end

  test "simulated peer down clears presence via Migrate" do
    dead = :peer_dead@host
    key = {"t1", "peer-down"}
    assert :ok = Presence.put_cohost(key, "eu", dead)
    assert :ok = Migrate.on_peer_hub_down(dead)
    refute Enum.any?(Presence.cohosts(key), &(&1.hub_node == dead))
  end
end
