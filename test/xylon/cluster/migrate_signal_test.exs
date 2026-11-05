defmodule Xylon.Cluster.MigrateSignalTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Migrate
  alias Xylon.Cluster.Presence

  setup do
    Presence.init!()
    Presence.reset!()
    :ok = Migrate.subscribe(self())
    on_exit(fn -> Migrate.unsubscribe(self()) end)
    :ok
  end

  test "notify_local_clients emits migrate_required with Placement target" do
    key = {"t1", "signal-room"}

    assert :ok = Migrate.notify_local_clients(key, :edge_down)

    assert_receive %{
                     type: :migrate_required,
                     session_key: ^key,
                     reason: :edge_down,
                     target: %{
                       node: node,
                       region_id: region,
                       role: role
                     }
                   },
                   500

    assert is_atom(node)
    assert is_binary(region)
    assert role in [:hub, :worker]
  end
end
