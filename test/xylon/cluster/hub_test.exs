defmodule Xylon.Cluster.HubTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Hub

  setup do
    Application.put_env(:xylon, :cluster,
      enabled: true,
      region_id: "test-region",
      hub_priority: 0,
      topologies: []
    )

    case Process.whereis(Hub) do
      nil ->
        {:ok, _pid} = start_supervised(Hub)

      _ ->
        :ok
    end

    :ok = Hub.set_membership_override(nil)
    :ok
  end

  test "elects self when alone" do
    assert :ok = Hub.set_membership_override([{Node.self(), 0}])
    assert :ok = Hub.reelect()
    assert Hub.hub_node() == Node.self()
    assert Hub.hub?()
  end

  test "loses hub when remote has higher priority" do
    remote = :remote_high@host
    assert :ok = Hub.set_membership_override([{Node.self(), 1}, {remote, 9}])
    assert :ok = Hub.reelect()
    assert Hub.hub_node() == remote
    refute Hub.hub?()
  end
end
