defmodule Xylon.SessionEchoRtpTest do
  use ExUnit.Case, async: false

  alias Xylon.{Forwarder, Participant, Session}
  alias XMediaLib.Rtp

  defmodule FakePeer do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])

    def drain(pid), do: GenServer.call(pid, :drain)

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call({:send_rtp, ssrc, packet}, _from, state) do
      {:reply, :ok, [{:send_rtp, ssrc, packet} | state]}
    end

    def handle_call(:drain, _from, state) do
      {:reply, Enum.reverse(state), []}
    end

    @impl true
    def handle_cast({:send_rtp, ssrc, packet}, state) do
      {:noreply, [{:send_rtp, ssrc, packet} | state]}
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "echo session sends RTP back to same peer via Forwarder" do
    assert {:ok, session} = Session.create("t1", "echo-rtp", :echo)
    assert {:ok, peer} = FakePeer.start_link()
    fwd = :sys.get_state(session).forwarder
    assert is_pid(fwd)
    assert fwd != session

    p = %Participant{id: "p1", peer_ref: peer, role: :echo}

    :sys.replace_state(session, fn state ->
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    assert :ok = Forwarder.install_echo(fwd, p)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 4242,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    send(fwd, {:xgw, :rtp, peer, rtp, %{}})
    refute_receive {:xgw, :rtp, ^peer, _, _}, 50

    assert_receive_echoed(peer, 4242)
  end

  test "Forwarder relays control events to Session" do
    assert {:ok, session} = Session.create("t1", "echo-ctrl", :echo)
    fwd = :sys.get_state(session).forwarder
    peer = self()

    send(fwd, {:xgw, :ice_connected, peer})
    send(fwd, {:xgw, :dtls_connected, peer})

    # Session swallows these with noreply; process must stay alive.
    assert Process.alive?(session)
    Process.sleep(20)
    assert Process.alive?(session)
  end

  test "Session mailbox stays clear of RTP during Forwarder burst" do
    assert {:ok, session} = Session.create("t1", "echo-burst", :echo)
    assert {:ok, peer} = FakePeer.start_link()
    fwd = :sys.get_state(session).forwarder
    p = %Participant{id: "p1", peer_ref: peer, role: :echo}

    :sys.replace_state(session, fn state ->
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    assert :ok = Forwarder.install_echo(fwd, p)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 4242,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    for seq <- 1..20 do
      send(fwd, {:xgw, :rtp, peer, %{rtp | sequence_number: seq}, %{}})
    end

    Process.sleep(50)
    assert {:messages, messages} = Process.info(session, :messages)
    refute Enum.any?(messages, &match?({:xgw, :rtp, _, _, _}, &1))
    assert length(FakePeer.drain(peer)) == 20
  end

  test "Peer DOWN drops Forwarder ETS plan" do
    assert {:ok, session} = Session.create("t1", "echo-down", :echo)
    assert {:ok, peer} = FakePeer.start_link()
    fwd = :sys.get_state(session).forwarder
    p = %Participant{id: "p1", peer_ref: peer, role: :echo}

    assert :ok = Forwarder.install_echo(fwd, p)
    assert {:ok, _} = Forwarder.plan_lookup(session, peer)

    GenServer.stop(peer)
    Process.sleep(50)

    assert :error = Forwarder.plan_lookup(session, peer)
  end

  defp assert_receive_echoed(peer, inbound_ssrc) do
    Enum.reduce_while(1..50, nil, fn _, _ ->
      case FakePeer.drain(peer) do
        [{:send_rtp, out_ssrc, %Rtp{} = out}] ->
          assert out_ssrc != inbound_ssrc
          assert out.ssrc == out_ssrc
          assert out.payload == "hi"
          {:halt, :ok}

        [] ->
          Process.sleep(10)
          {:cont, nil}

        other ->
          flunk("unexpected sends: #{inspect(other)}")
      end
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("timed out waiting for echoed send_rtp")
    end
  end
end
