defmodule Xylon.Forwarder.SendPoolTest do
  use ExUnit.Case, async: false

  alias Xylon.Forwarder
  alias Xylon.Forwarder.SendWorker
  alias Xylon.Participant
  alias XGW.Peer.SendHandle
  alias XMediaLib.Rtp

  defmodule FanBackend do
    @moduledoc false

    def init(_session, opts) do
      targets = Keyword.get(opts, :targets, [])
      {:ok, %{targets: targets}}
    end

    def handle_rtp(_participant, rtp, state) do
      specs =
        Enum.map(state.targets, fn %{participant: p, out_ssrc: out} ->
          {p, %{rtp | ssrc: out}}
        end)

      {:forward, specs, state}
    end

    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_reason, _state), do: :ok
  end

  defmodule SinkPeer do
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

    def handle_call(:drain, _from, state), do: {:reply, Enum.reverse(state), []}

    @impl true
    def handle_cast({:send_rtp, ssrc, packet}, state) do
      {:noreply, [{:send_rtp, ssrc, packet} | state]}
    end
  end

  setup do
    Forwarder.ensure_table!()
    :ok
  end

  test "default pool size is min(8, schedulers_online)" do
    session = self()
    expected = min(8, System.schedulers_online())
    previous = Application.get_env(:xylon, :send_workers)
    Application.delete_env(:xylon, :send_workers)
    on_exit(fn ->
      if previous, do: Application.put_env(:xylon, :send_workers, previous), else: Application.delete_env(:xylon, :send_workers)
    end)

    {:ok, fwd} =
      Forwarder.start_link(
        session: session,
        backend: FanBackend,
        session_id: "pool-default",
        tenant_id: "t",
        targets: []
      )

    workers = :sys.get_state(fwd).send_workers
    assert length(workers) == expected
    GenServer.stop(fwd)
  end

  test "terminate stops all send workers" do
    session = self()

    {:ok, fwd} =
      Forwarder.start_link(
        session: session,
        backend: FanBackend,
        session_id: "pool-term",
        tenant_id: "t",
        send_workers: 4,
        targets: []
      )

    workers = :sys.get_state(fwd).send_workers
    assert length(workers) == 4
    assert Enum.all?(workers, &Process.alive?/1)

    GenServer.stop(fwd)
    Process.sleep(50)
    refute Enum.any?(workers, &Process.alive?/1)
  end

  test "parallel workers deliver 1:N and keep per-subscriber seq monotonic" do
    session = self()
    {:ok, peer_pub} = SinkPeer.start_link()

    targets =
      for i <- 1..8 do
        {:ok, peer} = SinkPeer.start_link()
        p = %Participant{id: "s#{i}", peer_ref: peer}
        %{participant: p, out_ssrc: 1000 + i, peer: peer}
      end

    {:ok, fwd} =
      Forwarder.start_link(
        session: session,
        backend: FanBackend,
        session_id: "pool-seq",
        tenant_id: "t",
        send_workers: 4,
        targets: Enum.map(targets, &Map.take(&1, [:participant, :out_ssrc]))
      )

    pub = %Participant{id: "pub", peer_ref: peer_pub}
    assert :ok = Forwarder.put_plan(fwd, peer_pub, %{mode: :sfu, participant: pub})

    base = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 42,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    for seq <- 1..20 do
      send(fwd, {:xgw, :rtp, peer_pub, %{base | sequence_number: seq}, %{}})
    end

    Process.sleep(100)
    assert Process.alive?(fwd)

    for %{peer: peer, out_ssrc: out} <- targets do
      sends = SinkPeer.drain(peer)
      assert length(sends) == 20
      seqs = for {:send_rtp, ^out, %Rtp{sequence_number: s}} <- sends, do: s
      assert seqs == Enum.to_list(1..20)
    end
  end

  test "killed send worker does not crash Forwarder; later RTP still delivers" do
    session = self()
    {:ok, peer_pub} = SinkPeer.start_link()
    {:ok, peer_sub} = SinkPeer.start_link()
    sub = %Participant{id: "s", peer_ref: peer_sub}

    {:ok, fwd} =
      Forwarder.start_link(
        session: session,
        backend: FanBackend,
        session_id: "pool-kill",
        tenant_id: "t",
        send_workers: 2,
        targets: [%{participant: sub, out_ssrc: 77}]
      )

    pub = %Participant{id: "pub", peer_ref: peer_pub}
    assert :ok = Forwarder.put_plan(fwd, peer_pub, %{mode: :sfu, participant: pub})

    [w0 | _] = :sys.get_state(fwd).send_workers
    Process.exit(w0, :kill)
    Process.sleep(20)

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 42,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    send(fwd, {:xgw, :rtp, peer_pub, rtp, %{}})
    Process.sleep(50)
    assert Process.alive?(fwd)

    assert [{:send_rtp, 77, %Rtp{sequence_number: 1}}] = SinkPeer.drain(peer_sub)
  end

  test "worker timeout is contained; Forwarder stays alive" do
    session = self()
    {:ok, peer_pub} = SinkPeer.start_link()
    peer_sub = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer_sub, :kill) end)

    :ok = SendHandle.publish_passthrough(peer_sub, {__MODULE__, :slow_send, self()})

    sub = %Participant{id: "s", peer_ref: peer_sub}

    # Serial debug path still uses GenServer.call on the single worker.
    {:ok, fwd} =
      Forwarder.start_link(
        session: session,
        backend: FanBackend,
        session_id: "pool-to",
        tenant_id: "t",
        send_workers: 1,
        send_timeout: 50,
        targets: [%{participant: sub, out_ssrc: 9}]
      )

    pub = %Participant{id: "pub", peer_ref: peer_pub}
    assert :ok = Forwarder.put_plan(fwd, peer_pub, %{mode: :sfu, participant: pub})

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: "x"
    }

    send(fwd, {:xgw, :rtp, peer_pub, rtp, %{}})
    Process.sleep(200)
    assert Process.alive?(fwd)

    {:ok, peer_ok} = SinkPeer.start_link()
    ok = %Participant{id: "ok", peer_ref: peer_ok}

    :sys.replace_state(fwd, fn st ->
      %{st | backend_state: %{targets: [%{participant: ok, out_ssrc: 11}]}}
    end)

    send(fwd, {:xgw, :rtp, peer_pub, %{rtp | sequence_number: 2}, %{}})
    Process.sleep(50)
    assert Process.alive?(fwd)
    assert [{:send_rtp, 11, %Rtp{sequence_number: 2}}] = SinkPeer.drain(peer_ok)
  end

  def slow_send(_sink, _ssrc, _rtp) do
    Process.sleep(5_000)
    :ok
  end

  test "SendWorker.send_batch returns error on dead worker" do
    {:ok, worker} = SendWorker.start_link([])
    GenServer.stop(worker)
    assert {:error, _} = SendWorker.send_batch(worker, [])
  end
end
