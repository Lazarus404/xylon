defmodule Xylon.Trunk.ConnectRemoteTest do
  use ExUnit.Case, async: false

  alias XGW.Trunk.Pipe
  alias Xylon.Session
  alias Xylon.Trunk.Manager
  alias XMediaLib.Rtp

  @moduletag :dual_node

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
    ssrc: 7,
    csrcs: [],
    extension: nil,
    payload: <<"probe">>
  }

  test "connect_remote pairs same session_id on two nodes over UDP" do
    assert {:ok, %{a: _node_a, b: node_b, stop: stop}} = Xylon.Trunk.Lab.start_pair()
    on_exit(stop)

    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    assert :ok = :erpc.call(node_b, Xylon, :attach, [Xylon.Backend.Echo])

    sid = "room-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    assert {:ok, session_a} = Session.create("t1", sid, :echo)

    assert {:ok, trunk_a} =
             Manager.connect_remote(session_a, node_b,
               session_key: key,
               module_id: :echo,
               key_ab: @key_ab,
               salt_ab: @salt_ab,
               key_ba: @key_ba,
               salt_ba: @salt_ba
             )

    assert [{session_b, _}] =
             :erpc.call(node_b, Registry, :lookup, [Xylon.Registry, key])

    assert is_pid(session_b)
    assert node(session_a) == Node.self()

    pipe_a = trunk_a.peer_ref
    pipe_b = :erpc.call(node_b, Manager, :trunk_pipe, [session_b, "trunk"])
    assert is_pid(pipe_b)

    before = Pipe.stats(pipe_a)
    assert :ok = Pipe.send_rtp(pipe_a, 7, @rtp)
    Process.sleep(50)
    after_a = Pipe.stats(pipe_a)
    after_b = :erpc.call(node_b, Pipe, :stats, [pipe_b])

    assert after_a.udp_out > before.udp_out
    assert after_b.udp_in > 0
  end
end
