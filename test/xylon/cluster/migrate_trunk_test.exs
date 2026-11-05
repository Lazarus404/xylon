defmodule Xylon.Cluster.MigrateTrunkTest do
  use ExUnit.Case, async: false

  alias XGW.Trunk.Pipe
  alias Xylon.Cluster
  alias Xylon.Cluster.{Migrate, Trunk}
  alias Xylon.Trunk.Lab
  alias XMediaLib.Rtp

  @moduletag :cluster

  @key_ab <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @salt_ab <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>
  @key_ba <<0xA1B2C3D4E5F60718293A4B5C6D7E8F90::size(128)>>
  @salt_ba <<0x112233445566778899AABBCCDDEE::size(112)>>

  @rtp %Rtp{
    padding: 0,
    marker: 0,
    payload_type: 111,
    sequence_number: 1,
    timestamp: 1,
    ssrc: 9,
    csrcs: [],
    extension: nil,
    payload: <<"migrate">>
  }

  test "reconnect_cohosts after peer hub replacement restores UDP" do
    assert {:ok, %{b: node_b, regions: {_ra, rb}, stop: stop_b}} =
             Lab.start_hubs(["us-west-2", "eu-central-1"])

    on_exit(stop_b)

    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    assert :ok = :erpc.call(node_b, Xylon, :attach, [Xylon.Backend.Echo])

    sid = "mig-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    key_opts = [
      module_id: :echo,
      key_ab: @key_ab,
      salt_ab: @salt_ab,
      key_ba: @key_ba,
      salt_ba: @salt_ba
    ]

    assert {:ok, trunk_a} = Trunk.connect_hubs(key, node_b, key_opts)
    pipe_a = trunk_a.peer_ref
    before = Pipe.stats(pipe_a)
    assert :ok = Pipe.send_rtp(pipe_a, 9, @rtp)
    Process.sleep(50)
    assert Pipe.stats(pipe_a).udp_out > before.udp_out

    stop_b.()
    Process.sleep(100)

    assert :ok = Migrate.on_peer_hub_down(node_b)

    assert {:ok, %{node: node_c, stop: stop_c}} = Lab.start_extra_hub(rb, :edge_c)
    on_exit(stop_c)
    assert :ok = :erpc.call(node_c, Xylon, :attach, [Xylon.Backend.Echo])

    assert {:ok, trunk2} =
             Trunk.reconnect_cohosts(
               key,
               key_opts ++ [peer_hub_node: node_c, peer_region: rb]
             )

    pipe2 = trunk2.peer_ref
    mid = Pipe.stats(pipe2)
    assert :ok = Pipe.send_rtp(pipe2, 9, %{@rtp | sequence_number: 2})
    Process.sleep(50)
    assert Pipe.stats(pipe2).udp_out > mid.udp_out

    assert Enum.any?(Cluster.Presence.cohosts(key), &(&1.hub_node == node_c))
  end

  test "on_peer_hub_up auto reconnects when trunk_keys configured" do
    assert {:ok, %{b: node_b, regions: {_ra, rb}, stop: stop_b}} =
             Lab.start_hubs(["us-west-2", "eu-central-1"])

    on_exit(stop_b)

    prev = Application.get_env(:xylon, :cluster, [])

    Application.put_env(
      :xylon,
      :cluster,
      Keyword.merge(prev,
        trunk_keys: [
          key_ab: @key_ab,
          salt_ab: @salt_ab,
          key_ba: @key_ba,
          salt_ba: @salt_ba
        ]
      )
    )

    on_exit(fn -> Application.put_env(:xylon, :cluster, prev) end)

    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    assert :ok = :erpc.call(node_b, Xylon, :attach, [Xylon.Backend.Echo])

    sid = "auto-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    key_opts = [
      module_id: :echo,
      key_ab: @key_ab,
      salt_ab: @salt_ab,
      key_ba: @key_ba,
      salt_ba: @salt_ba
    ]

    assert {:ok, trunk_a} = Trunk.connect_hubs(key, node_b, key_opts)
    pipe_a = trunk_a.peer_ref

    stop_b.()
    Process.sleep(100)
    assert :ok = Migrate.on_peer_hub_down(node_b)

    assert {:ok, %{node: node_c, stop: stop_c}} = Lab.start_extra_hub(rb, :edge_d)
    on_exit(stop_c)
    assert :ok = :erpc.call(node_c, Xylon, :attach, [Xylon.Backend.Echo])

    assert :ok = Migrate.on_peer_hub_up(node_c)
    Process.sleep(100)

    assert Enum.any?(Cluster.Presence.cohosts(key), &(&1.hub_node == node_c))

    [{session, _}] = Registry.lookup(Xylon.Registry, key)
    pipe2 = Xylon.Trunk.Manager.trunk_pipe(session, "trunk")
    assert is_pid(pipe2)
    mid = Pipe.stats(pipe2)
    assert :ok = Pipe.send_rtp(pipe2, 9, %{@rtp | sequence_number: 3})
    Process.sleep(50)
    assert Pipe.stats(pipe2).udp_out > mid.udp_out
    _ = pipe_a
  end
end
