defmodule Xylon.Cluster.MigrateControlPushTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Presence
  alias Xylon.Cluster.Migrate

  setup do
    start_supervised!(Xylon.Control.Membership)
    start_supervised!(Presence)
    :ok
  end

  test "notify_local_clients pushes migrate_required to Control WS subscribers" do
    assert :ok = Presence.subscribe("t1", "s-mig", "viewer", self())

    assert :ok = Migrate.notify_local_clients({"t1", "s-mig"}, :edge_down)

    assert_receive {:xylon_control_presence,
                    %{
                      type: :migrate_required,
                      reason: :edge_down,
                      session_key: {"t1", "s-mig"},
                      target: %{node: node, region_id: region}
                    }},
                   500

    assert is_binary(node)
    assert is_binary(region)
  end
end
