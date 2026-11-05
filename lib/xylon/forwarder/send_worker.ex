defmodule Xylon.Forwarder.SendWorker do
  @moduledoc """
  Per-Forwarder RTP send worker for parallel SFU egress.

  ## What problem this solves

  A Session Forwarder rewrites and NACKs inbound RTP serially, then must send
  many outbound copies. Sending all copies on the Forwarder process makes
  tail latency grow with subscriber count when each send does real SRTP/UDP
  work. This worker owns two FIFO queues of `{participant, packet}` specs so
  the Forwarder can hash-partition by outbound SSRC and `GenServer.call` only
  to **enqueue** (accepted, not yet on the wire):

  - **ready** -- audio / non-paceable / record: drained immediately
  - **paced** -- video (`Xylon.Forwarder.EgressPace`): same worker queue;
    passthrough timing (`due == now`) so RTP is not re-clocked on egress

  Audio never waits behind a video packet that is not yet due. Optional
  `:stamp_t0` copies the MCU bench tick mark into this process for FakePeer
  `mcu_tick_to_egress` sampling.

  **Internal:** owned by `Xylon.Forwarder` (one pool per Forwarder / Session).

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP send order per SSRC)
  """

  use GenServer

  alias XGW.Peer
  alias XGW.Peer.SendHandle
  alias Xylon.Forwarder.EgressPace

  @doc """
  Starts an unlinked send worker (Forwarder pool ownership).
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) when is_list(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Starts a linked send worker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Enqueues one batch of `{participant, packet}` specs for paced / ready send.

  Returns `:ok` when the batch is accepted (not when every packet is on the
  wire). Third argument is a timeout (ms or `:infinity`) or a keyword list with
  `:timeout` and optional `:stamp_t0` (bench MCU tick mark copied into this
  worker's process dictionary for FakePeer `mcu_tick_to_egress`).

  Per-leg SendHandle errors use the same Peer async fallback as
  `Xylon.Forwarder`. Does not crash the caller on individual send failures.
  """
  @spec send_batch(pid(), [{Xylon.Participant.t(), term()}], timeout() | keyword()) ::
          :ok | {:error, term()}
  def send_batch(worker, specs, timeout_or_opts \\ 5_000)

  def send_batch(worker, specs, timeout)
      when is_pid(worker) and is_list(specs) and
             (is_integer(timeout) or timeout == :infinity) do
    do_send_batch(worker, specs, timeout, nil)
  end

  def send_batch(worker, specs, opts) when is_pid(worker) and is_list(specs) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    stamp_t0 = Keyword.get(opts, :stamp_t0)
    do_send_batch(worker, specs, timeout, stamp_t0)
  end

  defp do_send_batch(worker, specs, timeout, stamp_t0) do
    GenServer.call(worker, {:send_batch, specs, stamp_t0}, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(_opts) do
    {:ok, %{pace: %{}, ready: :queue.new(), paced: :queue.new(), timer: nil}}
  end

  @impl true
  def handle_call({:send_batch, specs, stamp_t0}, _from, state) do
    if is_integer(stamp_t0) do
      _ = Process.put(:xylon_mcu_tick_t0, stamp_t0)
    else
      _ = Process.delete(:xylon_mcu_tick_t0)
    end

    state =
      Enum.reduce(specs, state, fn spec, st ->
        case spec do
          {_dest, packet} ->
            if EgressPace.paceable?(packet) do
              %{st | paced: :queue.in(spec, st.paced)}
            else
              %{st | ready: :queue.in(spec, st.ready)}
            end

          _ ->
            %{st | ready: :queue.in(spec, st.ready)}
        end
      end)

    state = cancel_timer(state)
    state = drain_loop(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    state = %{state | timer: nil}
    {:noreply, drain_loop(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_timer(state)

    Enum.each(:queue.to_list(state.ready) ++ :queue.to_list(state.paced), fn
      {%{type: :record} = dest, packet} ->
        _ = Xylon.Recording.LayoutSink.ingest(dest, packet)

      {%{peer_ref: peer_ref}, packet} when is_pid(peer_ref) ->
        _ = forward_rtp(peer_ref, rtp_ssrc(packet), packet)

      _ ->
        :ok
    end)

    :ok
  end

  defp drain_loop(state) do
    state = drain_ready(state)
    drain_paced(state)
  end

  defp drain_ready(state) do
    case :queue.out(state.ready) do
      {:empty, ready} ->
        %{state | ready: ready}

      {{:value, spec}, ready} ->
        _ = send_spec_now(spec)
        drain_ready(%{state | ready: ready})
    end
  end

  defp drain_paced(state) do
    case :queue.out(state.paced) do
      {:empty, paced} ->
        %{state | paced: paced}

      {{:value, spec}, paced} ->
        now = System.monotonic_time(:microsecond)

        case spec do
          {%{peer_ref: peer_ref}, packet} when is_pid(peer_ref) ->
            {due, catch_up?, key} = EgressPace.due_for(state.pace, peer_ref, packet, now)

            case EgressPace.wait_plan(due, now) do
              {:delay_ms, delay_ms} ->
                hold_us = max(0, due - now)

                :telemetry.execute(
                  [:xylon, :rtp, :egress],
                  %{hold_us: hold_us},
                  %{kind: :video}
                )

                timer = Process.send_after(self(), :drain, delay_ms)
                %{state | paced: :queue.in_r(spec, paced), timer: timer}

              :immediate ->
                :telemetry.execute(
                  [:xylon, :rtp, :egress],
                  %{hold_us: 0},
                  %{kind: :video}
                )

                _ = forward_rtp(peer_ref, rtp_ssrc(packet), packet)
                send_us = System.monotonic_time(:microsecond)
                pace = EgressPace.put_after(state.pace, key, packet, send_us, catch_up?)
                drain_loop(%{state | paced: paced, pace: pace})
            end

          _ ->
            _ = send_spec_now(spec)
            drain_loop(%{state | paced: paced})
        end
    end
  end

  defp send_spec_now({%{type: :record} = dest, packet}) do
    Xylon.Recording.LayoutSink.ingest(dest, packet)
  end

  defp send_spec_now({%{peer_ref: peer_ref}, packet}) when is_pid(peer_ref) do
    forward_rtp(peer_ref, rtp_ssrc(packet), packet)
  end

  defp send_spec_now(_), do: :ok

  defp cancel_timer(%{timer: ref} = state) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp forward_rtp(peer_ref, ssrc, packet) do
    case SendHandle.send_rtp(peer_ref, ssrc, packet) do
      :ok -> :ok
      {:error, _} -> Peer.send_rtp_async(peer_ref, ssrc, packet)
    end
  end

  defp rtp_ssrc(%{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  defp rtp_ssrc(_), do: 0
end
