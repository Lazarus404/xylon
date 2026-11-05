defmodule Xylon.Forwarder.SendWorkerTest do
  use ExUnit.Case, async: true

  alias Xylon.Forwarder
  alias Xylon.Forwarder.SendWorker
  alias Xylon.Participant
  alias XGW.Peer.SendHandle
  alias XMediaLib.Rtp

  test "partition_specs keeps same out_ssrc on same worker index" do
    pkt = fn ssrc -> %Rtp{ssrc: ssrc, sequence_number: 1, payload: "x"} end
    p = %Participant{id: "b", peer_ref: self()}

    specs =
      for ssrc <- [10, 20, 10, 30, 20] do
        {p, pkt.(ssrc)}
      end

    chunks = Forwarder.partition_specs(specs, 4)
    assert length(chunks) == 4

    idx10 = :erlang.phash2(10, 4)
    idx20 = :erlang.phash2(20, 4)

    assert Enum.count(Enum.at(chunks, idx10), fn {_, %Rtp{ssrc: s}} -> s == 10 end) == 2
    assert Enum.count(Enum.at(chunks, idx20), fn {_, %Rtp{ssrc: s}} -> s == 20 end) == 2
  end

  test "send_batch delivers via SendHandle passthrough" do
    peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer, :kill) end)

    :ok = SendHandle.publish_passthrough(peer, {__MODULE__, :note, self()})

    {:ok, worker} = SendWorker.start_link([])
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)

    p = %Participant{id: "x", peer_ref: peer}
    pkt = %Rtp{ssrc: 9, sequence_number: 1, payload: "hi"}
    assert :ok = SendWorker.send_batch(worker, [{p, pkt}])
    assert_receive {:sent, 9, %Rtp{payload: "hi"}}, 500
  end

  test "send_batch stamp_t0 is visible during MFA send" do
    parent = self()

    peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer, :kill) end)

    :ok =
      SendHandle.publish_passthrough(peer, {__MODULE__, :note_t0, parent})

    {:ok, worker} = SendWorker.start_link([])
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)

    p = %Participant{id: "x", peer_ref: peer}
    pkt = %Rtp{ssrc: 9, sequence_number: 1, payload: "hi"}
    assert :ok = SendWorker.send_batch(worker, [{p, pkt}], timeout: 5_000, stamp_t0: 42)
    assert_receive {:sent_t0, 42}, 500
  end

  test "send_batch on dead worker returns error without raising" do
    {:ok, worker} = SendWorker.start_link([])
    GenServer.stop(worker, :normal)
    assert {:error, _} = SendWorker.send_batch(worker, [])
  end

  test "send_batch enqueues quickly and sends same-ts video back-to-back" do
    parent = self()
    peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer, :kill) end)

    :ok = SendHandle.publish_passthrough(peer, {__MODULE__, :note_ts, parent})

    {:ok, worker} = SendWorker.start_link([])
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)

    p = %Participant{id: "v", peer_ref: peer}
    n = 6

    specs =
      for seq <- 1..n do
        {p,
         %Rtp{
           padding: 0,
           marker: 0,
           payload_type: 96,
           sequence_number: seq,
           timestamp: 9000,
           ssrc: 42,
           csrcs: [],
           extension: nil,
           payload: <<"vv">>
         }}
      end

    t0 = System.monotonic_time(:microsecond)
    assert :ok = SendWorker.send_batch(worker, specs)
    call_us = System.monotonic_time(:microsecond) - t0
    assert call_us < 2_000

    times =
      for _ <- 1..n do
        assert_receive {:sent_ts, t}, 5_000
        t
      end

    span = List.last(times) - hd(times)
    # Frame burst: all same-ts packets leave immediately (no 500us intra gaps).
    assert span < 2_000
  end

  test "send_batch sends distinct-ts video back-to-back (no RTP re-clock hold)" do
    parent = self()
    peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer, :kill) end)

    :ok = SendHandle.publish_passthrough(peer, {__MODULE__, :note_ts, parent})

    {:ok, worker} = SendWorker.start_link([])
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)

    p = %Participant{id: "v", peer_ref: peer}

    specs =
      for {seq, ts} <- [{1, 0}, {2, 3000}, {3, 6000}] do
        {p,
         %Rtp{
           padding: 0,
           marker: 0,
           payload_type: 96,
           sequence_number: seq,
           timestamp: ts,
           ssrc: 7,
           csrcs: [],
           extension: nil,
           payload: <<"frame">>
         }}
      end

    t0 = System.monotonic_time(:microsecond)
    assert :ok = SendWorker.send_batch(worker, specs)
    assert System.monotonic_time(:microsecond) - t0 < 5_000

    times =
      for _ <- 1..3 do
        assert_receive {:sent_ts, t}, 5_000
        t
      end

    span = List.last(times) - hd(times)
    # Must not re-clock to ~66ms of RTP gaps.
    assert span < 5_000
  end

  test "audio is not blocked behind paced same-ts video" do
    parent = self()
    peer = spawn(fn -> :timer.sleep(:infinity) end)
    on_exit(fn -> Process.exit(peer, :kill) end)

    :ok = SendHandle.publish_passthrough(peer, {__MODULE__, :note_kind, parent})

    {:ok, worker} = SendWorker.start_link([])
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)

    p = %Participant{id: "av", peer_ref: peer}

    video = fn seq ->
      {p,
       %Rtp{
         padding: 0,
         marker: 0,
         payload_type: 96,
         sequence_number: seq,
         timestamp: 9000,
         ssrc: 42,
         csrcs: [],
         extension: nil,
         payload: <<"vv">>
       }}
    end

    audio = fn seq ->
      {p,
       %Rtp{
         padding: 0,
         marker: 0,
         payload_type: 111,
         sequence_number: seq,
         timestamp: seq * 960,
         ssrc: 99,
         csrcs: [],
         extension: nil,
         payload: <<"a">>
       }}
    end

    # Two same-ts video then audio -- audio must not HOL behind paced video.
    specs = [video.(1), video.(2), audio.(1), audio.(2), audio.(3), audio.(4)]
    assert :ok = SendWorker.send_batch(worker, specs)

    events =
      for _ <- 1..6 do
        assert_receive {:sent_kind, kind, t, seq}, 5_000
        {kind, t, seq}
      end

    kinds = Enum.map(events, &elem(&1, 0))
    # Ready (audio) drains before paced video.
    assert kinds == [:audio, :audio, :audio, :audio, :video, :video]

    audio_times =
      events
      |> Enum.filter(fn {k, _, _} -> k == :audio end)
      |> Enum.map(fn {_, t, _} -> t end)

    audio_gaps =
      audio_times
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    assert audio_gaps != []
    assert Enum.max(audio_gaps) < 5_000

    video_times =
      events
      |> Enum.filter(fn {k, _, _} -> k == :video end)
      |> Enum.map(fn {_, t, _} -> t end)

    assert length(video_times) == 2
    # Same-ts burst: back-to-back, not artificially gapped.
    assert Enum.at(video_times, 1) - Enum.at(video_times, 0) < 2_000
  end

  def note(sink, ssrc, rtp) do
    send(sink, {:sent, ssrc, rtp})
    :ok
  end

  def note_t0(sink, _ssrc, _rtp) do
    send(sink, {:sent_t0, Process.get(:xylon_mcu_tick_t0)})
    :ok
  end

  def note_ts(sink, _ssrc, _rtp) do
    send(sink, {:sent_ts, System.monotonic_time(:microsecond)})
    :ok
  end

  def note_kind(sink, _ssrc, rtp) do
    kind = if rtp.payload_type == 111, do: :audio, else: :video
    send(sink, {:sent_kind, kind, System.monotonic_time(:microsecond), rtp.sequence_number})
    :ok
  end
end
