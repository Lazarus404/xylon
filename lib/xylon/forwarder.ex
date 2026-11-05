defmodule Xylon.Forwarder do
  @moduledoc """
  In-process media handler for XGW Peers in a session.

  ## What problem this solves

  Decrypted audio/video arrives as a high rate of small messages. Routing them
  through a session GenServer would serialize media on a single mailbox. The
  Forwarder is registered as each Peer `handler:` so RTP, RTCP, and datachannel
  payloads go straight to `Xylon.Backend` callbacks and back out via
  [XGW](https://github.com/Lazarus404/xgw) `SendHandle`, while lifecycle events
  (ICE connected, DTLS up, peer closed, SCTP, local ICE trickle) are relayed to
  `Xylon.Session` unchanged.

  Per-peer **plans** in ETS map an inbound Peer to forwarding mode (`:echo`,
  `:sfu`, or `:datachannel`) and the `%Xylon.Participant{}` record. Session
  installs plans after join via `put_plan/3` or `install_echo/2`.

  ponytail: one Forwarder GenServer per Session owns a small pool of
  `Xylon.Forwarder.SendWorker` processes (default `min(8, schedulers_online)`).
  RTP rewrite/NACK stay on the Forwarder; completed fanout specs are
  hash-partitioned by outbound SSRC and enqueued via awaited `GenServer.call`
  (`:ok` means accepted, not on the wire). Workers drain audio/ready immediately
  and video on a separate paced queue with **passthrough** timing
  (`Xylon.Forwarder.EgressPace`, `due == now`) so egress does not re-clock RTP.
  `send_workers: 1`
  forces a single serial worker for debug. `send_workers: 0` sends inline
  (tests / rare fallback; unpaced specs first). DC fanout stays inline.

  Plan mutations are `put_plan` / `install_echo` / `remove_peer` / `invalidate`.
  Peers are monitored; a `:DOWN` drops the ETS row so sends never target a dead pid.

  ## RFCs and related specs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) -- RTP forwarded here
  - [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764) -- DTLS-SRTP terminated in XGW before this layer
  """

  use GenServer

  require Logger

  alias XGW.Peer
  alias XGW.Peer.SendHandle
  alias Xylon.Forwarder.EgressPace
  alias Xylon.Forwarder.SendWorker
  alias Xylon.Participant

  @table :xylon_forward
  @default_send_timeout 5_000

  @typedoc """
  ETS plan row for one inbound Peer.

  ## Fields

  - `:mode` - `:echo` loops to the same participant; `:sfu` selects fan-out
    routes; `:datachannel` uses the datachannel Backend for DC fanout/MFU.
  - `:participant` - `%Xylon.Participant{}` for the Peer that owns this plan row.
  - Other keys - Backend-specific (e.g. subscribe targets); optional.
  """
  @type plan :: %{
          optional(atom()) => term(),
          mode: :echo | :sfu | :datachannel,
          participant: Participant.t()
        }

  @doc """
  Creates the forward-plan ETS table if it does not exist.

  Called from `Xylon.Application` at boot and before plan lookups.
  """
  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Starts a Forwarder linked to session pid `session`.

  Requires `:session` and `:backend` in opts. Pass the same keyword opts as
  Session init (tenant, session_id, mode, labels, tap, ...) so Backend state
  matches on both control and media paths.

  Opts: `:send_workers` (non-neg integer, default `min(8, schedulers_online)`;
  `1` forces serial single-worker egress for debug; `0` sends inline on the
  Forwarder), `:send_timeout` (ms for each worker batch call, default 5000).
  Override via `config :xylon, :send_workers`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Partitions forward specs into `n` chunks by outbound RTP SSRC.

  Same `out_ssrc` always maps to the same chunk index so per-SSRC FIFO is
  preserved when each chunk is sent on one worker.
  """
  @spec partition_specs([{Participant.t(), term()}], pos_integer()) :: [
          [{Participant.t(), term()}]
        ]
  def partition_specs(specs, n) when is_list(specs) and is_integer(n) and n <= 1, do: [specs]

  def partition_specs(specs, n) when is_list(specs) and is_integer(n) and n > 1 do
    Enum.reduce(specs, List.duplicate([], n), fn {_p, packet} = spec, acc ->
      i = :erlang.phash2(rtp_ssrc(packet), n)
      List.update_at(acc, i, &[spec | &1])
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  @doc """
  Installs or replaces the plan row for `peer`.

  `plan` must include `:participant` (and typically `:mode`).
  """
  @spec put_plan(pid(), pid(), map()) :: :ok
  def put_plan(forwarder, peer, plan)
      when is_pid(forwarder) and is_pid(peer) and is_map(plan) do
    GenServer.call(forwarder, {:put_plan, peer, plan})
  end

  @doc """
  Installs Echo mode: RTP and datachannel from `participant` loop back to their Peer.
  """
  @spec install_echo(pid(), Participant.t()) :: :ok
  def install_echo(forwarder, %Participant{peer_ref: peer} = participant)
      when is_pid(forwarder) and is_pid(peer) do
    put_plan(forwarder, peer, %{mode: :echo, participant: participant})
  end

  @doc """
  Sends datachannel forward specs via SendHandle, falling back to async Peer send.

  Used by Forwarder inbound fanout and by Session for publish / open flush.
  Reads `:dc_ppi` from `backend_state` (`:string` default, `:binary` for Msgpack).
  """
  @spec send_dc_specs([{Participant.t(), reference(), binary()}], map()) :: :ok
  def send_dc_specs(specs, backend_state) when is_list(specs) and is_map(backend_state) do
    type = Map.get(backend_state, :dc_ppi, :string)

    Enum.each(specs, fn {p, ref, payload} ->
      case SendHandle.send_datachannel(p.peer_ref, ref, payload, type) do
        :ok ->
          :ok

        {:error, _} ->
          Peer.send_datachannel_async(p.peer_ref, ref, payload, type)
      end
    end)
  end

  @doc """
  Removes the ETS plan and monitor for one Peer (leave or closed).
  """
  @spec remove_peer(pid(), pid()) :: :ok
  def remove_peer(forwarder, peer) when is_pid(forwarder) and is_pid(peer) do
    GenServer.call(forwarder, {:remove_peer, peer})
  end

  @doc """
  Clears every plan and peer monitor owned by this Forwarder.

  Called when the Session terminates.
  """
  @spec invalidate(pid()) :: :ok
  def invalidate(forwarder) when is_pid(forwarder) do
    GenServer.call(forwarder, :invalidate)
  end

  @doc false
  @spec plan_lookup(pid(), pid()) :: {:ok, plan()} | :error
  def plan_lookup(session, peer) when is_pid(session) and is_pid(peer) do
    ensure_table!()

    case :ets.lookup(@table, {session, peer}) do
      [{_, %{} = row}] -> {:ok, row}
      [] -> :error
    end
  end

  @impl true
  def init(opts) do
    ensure_table!()
    session = Keyword.fetch!(opts, :session)
    backend = Keyword.fetch!(opts, :backend)
    n_workers = send_worker_count(opts)
    send_timeout = Keyword.get(opts, :send_timeout, @default_send_timeout)

    session_struct = %Xylon.Session{
      id: Keyword.get(opts, :session_id),
      tenant_id: Keyword.get(opts, :tenant_id),
      backend: backend
    }

    init_opts = Keyword.put(opts, :session_pid, session)

    case backend.init(session_struct, init_opts) do
      {:ok, backend_state} ->
        workers = start_send_workers(n_workers)

        {:ok,
         %{
           session: session,
           backend: backend,
           backend_state: backend_state,
           peer_mons: %{},
           pending_dc_opens: %{},
           send_workers: workers,
           send_timeout: send_timeout,
           pace: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:put_plan, peer, plan}, _from, state) when is_pid(peer) and is_map(plan) do
    participant = Map.fetch!(plan, :participant)
    plan = Map.put(plan, :participant, participant)
    # Preserve early DC open buffered before put_plan (drop_peer clears pending).
    pending_info = Map.get(Map.get(state, :pending_dc_opens, %{}), peer)
    state = drop_peer(state, peer)
    ref = Process.monitor(peer)
    true = :ets.insert(@table, {{state.session, peer}, plan})
    state = %{state | peer_mons: Map.put(state.peer_mons, peer, ref)}

    state =
      if is_map(pending_info) do
        apply_dc_open(state, participant, pending_info)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:remove_peer, peer}, _from, state) do
    {:reply, :ok, drop_peer(state, peer)}
  end

  def handle_call(:invalidate, _from, state) do
    state =
      Enum.reduce(Map.keys(state.peer_mons), state, fn peer, acc ->
        drop_peer(acc, peer)
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, peer, _reason}, state) do
    case Map.get(state.peer_mons, peer) do
      ^ref ->
        {:noreply, drop_peer(state, peer)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:xgw, :rtp, peer, rtp, meta}, state) when is_map(meta) do
    state = handle_media_rtp(state, peer, rtp, meta)
    {:noreply, state}
  end

  def handle_info({:xgw, :rtp, peer, rtp, _meta}, state) do
    state = handle_media_rtp(state, peer, rtp, %{})
    {:noreply, state}
  end

  def handle_info({:xgw, :rtcp, peer, rtcp, _meta}, state) do
    state = handle_media_rtcp(state, peer, rtcp)
    {:noreply, state}
  end

  def handle_info({:xgw, :datachannel_message, peer, channel_ref, data}, state) do
    state = handle_media_dc(state, peer, channel_ref, data)
    {:noreply, state}
  end

  def handle_info({:xgw, :datachannel_send_error, peer, channel_ref, reason}, state) do
    :telemetry.execute(
      [:xylon, :dc, :egress_drop],
      %{count: 1},
      %{peer: peer, channel_ref: channel_ref, reason: reason, session: state.session}
    )

    {:noreply, state}
  end

  def handle_info({:xgw, :datachannel, peer, info}, state) when is_map(info) do
    state = maybe_register_dc_open(state, peer, info)
    relay(state.session, {:xgw, :datachannel, peer, info})
    {:noreply, state}
  end

  def handle_info({:xgw, _, _, _} = msg, state) do
    relay(state.session, msg)
    {:noreply, state}
  end

  def handle_info({:xgw, _, _, _, _} = msg, state) do
    relay(state.session, msg)
    {:noreply, state}
  end

  def handle_info({:xgw, _, _} = msg, state) do
    relay(state.session, msg)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.get(state, :send_workers, []), &stop_send_worker/1)

    Enum.each(state.peer_mons, fn {peer, ref} ->
      Process.demonitor(ref, [:flush])
      true = :ets.delete(@table, {state.session, peer})
    end)

    :ok
  end

  defp drop_peer(state, peer) do
    pending = Map.get(state, :pending_dc_opens, %{})
    state = %{state | pending_dc_opens: Map.delete(pending, peer)}

    case Map.pop(state.peer_mons, peer) do
      {nil, _} ->
        true = :ets.delete(@table, {state.session, peer})
        state

      {ref, mons} ->
        Process.demonitor(ref, [:flush])
        true = :ets.delete(@table, {state.session, peer})
        %{state | peer_mons: mons}
    end
  end

  defp handle_media_rtp(state, peer, rtp, meta) do
    if Xylon.Profile.enabled?() do
      t0 = System.monotonic_time(:microsecond)
      mb = mailbox_len()
      {state, forwarded} = do_handle_media_rtp(state, peer, rtp, meta)

      :telemetry.execute(
        [:xylon, :rtp, :forward],
        %{
          duration_us: System.monotonic_time(:microsecond) - t0,
          mailbox: mb,
          forwarded: forwarded
        },
        %{session: state.session, kind: rtp_kind(rtp)}
      )

      state
    else
      {state, _forwarded} = do_handle_media_rtp(state, peer, rtp, meta)
      state
    end
  end

  defp do_handle_media_rtp(state, peer, rtp, meta) do
    prev_arrival = Process.get(:xylon_rtp_arrival_us)

    case Map.get(meta, :arrival_us) do
      us when is_integer(us) -> Process.put(:xylon_rtp_arrival_us, us)
      _ -> Process.delete(:xylon_rtp_arrival_us)
    end

    try do
      case plan(state.session, peer) do
        {:ok, %{participant: participant}} ->
          case state.backend.handle_rtp(participant, rtp, state.backend_state) do
            {:forward, specs, backend_state} ->
              state = %{state | backend_state: backend_state}
              state = dispatch_send_specs(state, specs)
              {state, length(specs)}

            {:ok, backend_state} ->
              {%{state | backend_state: backend_state}, 0}

            {:error, _} ->
              {state, 0}
          end

        :error ->
          {state, 0}
      end
    after
      restore_arrival_us(prev_arrival)
    end
  end

  defp restore_arrival_us(nil), do: Process.delete(:xylon_rtp_arrival_us)
  defp restore_arrival_us(prev), do: Process.put(:xylon_rtp_arrival_us, prev)

  # Lab PT heuristic: static audio + common Opus 111 vs dynamic video PTs.
  defp rtp_kind(%{payload_type: pt}) when pt in [0, 8, 9, 10, 11, 111], do: :audio
  defp rtp_kind(%{payload_type: pt}) when is_integer(pt) and pt >= 96, do: :video
  defp rtp_kind(_), do: :unknown

  defp mailbox_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  defp dispatch_send_specs(state, []), do: state

  defp dispatch_send_specs(state, specs) when is_list(specs) do
    workers = Map.get(state, :send_workers, [])
    n = length(workers)
    timeout = Map.get(state, :send_timeout, @default_send_timeout)
    stamp_t0 = Process.get(:xylon_mcu_tick_t0)

    if n <= 1 do
      dispatch_serial(state, specs, timeout, stamp_t0)
    else
      dispatch_parallel(state, specs, n, timeout, stamp_t0)
    end
  end

  defp dispatch_serial(state, specs, timeout, stamp_t0) do
    case maybe_worker(state, 0) do
      {nil, state} ->
        pace = send_specs_inline(specs, Map.get(state, :pace, %{}))
        %{state | pace: pace}

      {worker, state} ->
        case SendWorker.send_batch(worker, specs, timeout: timeout, stamp_t0: stamp_t0) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning(
              "xylon send_worker batch failed session=#{inspect(state.session)} reason=#{inspect(reason)}"
            )

            retire_worker(state, worker)
        end
    end
  end

  defp dispatch_parallel(state, specs, n, timeout, stamp_t0) do
    chunks = partition_specs(specs, n)

    {state, work} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({state, []}, fn {chunk, i}, {st, acc} ->
        if chunk == [] do
          {st, acc}
        else
          {worker, st} = maybe_worker(st, i)

          item =
            if is_pid(worker), do: {:worker, worker, chunk}, else: {:inline, chunk}

          {st, [item | acc]}
        end
      end)

    case work do
      [] ->
        state

      [_] ->
        # One non-empty chunk: no Task fan-out needed.
        dispatch_work_item(state, hd(work), timeout, stamp_t0)

      _ ->
        results =
          work
          |> Task.async_stream(
            fn
              {:worker, worker, chunk} ->
                case SendWorker.send_batch(worker, chunk, timeout: timeout, stamp_t0: stamp_t0) do
                  :ok -> :ok
                  {:error, reason} -> {:error, worker, reason}
                end

              {:inline, chunk} ->
                # Fallback only: pace map is not shared across Tasks.
                _ = send_specs_inline(chunk, %{})
                :ok
            end,
            ordered: false,
            timeout: timeout + 1_000,
            on_timeout: :kill_task,
            zip_input_on_exit: true
          )
          |> Enum.to_list()

        Enum.reduce(results, state, fn
          {:ok, :ok}, st ->
            st

          {:ok, {:error, worker, reason}}, st ->
            Logger.warning(
              "xylon send_worker chunk failed session=#{inspect(st.session)} reason=#{inspect(reason)}"
            )

            retire_worker(st, worker)

          {:exit, reason}, st ->
            Logger.warning(
              "xylon send_worker chunk exit session=#{inspect(st.session)} reason=#{inspect(reason)}"
            )

            st
        end)
    end
  end

  defp dispatch_work_item(state, {:inline, chunk}, _timeout, _stamp_t0) do
    pace = send_specs_inline(chunk, Map.get(state, :pace, %{}))
    %{state | pace: pace}
  end

  defp dispatch_work_item(state, {:worker, worker, chunk}, timeout, stamp_t0) do
    case SendWorker.send_batch(worker, chunk, timeout: timeout, stamp_t0: stamp_t0) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning(
          "xylon send_worker chunk failed session=#{inspect(state.session)} reason=#{inspect(reason)}"
        )

        retire_worker(state, worker)
    end
  end

  # ponytail: `:timer.sleep` only for send_workers: 0 / failed-worker fallback;
  # production uses the SendWorker pool (async RTP-clock drain).
  # Unpaced (audio/record) first so inline wait on video cannot HOL audio.
  defp send_specs_inline(specs, pace) do
    {paced, ready} =
      Enum.split_with(specs, fn
        {_dest, packet} -> EgressPace.paceable?(packet)
        _ -> false
      end)

    pace = Enum.reduce(ready, pace, &send_inline_one/2)
    Enum.reduce(paced, pace, &send_inline_one/2)
  end

  defp send_inline_one({%{type: :record} = dest, packet}, pace) do
    _ = Xylon.Recording.LayoutSink.ingest(dest, packet)
    pace
  end

  defp send_inline_one({%{peer_ref: peer_ref}, packet}, pace) when is_pid(peer_ref) do
    now = System.monotonic_time(:microsecond)
    {due, catch_up?, key} = EgressPace.due_for(pace, peer_ref, packet, now)

    case EgressPace.wait_plan(due, now) do
      {:delay_ms, delay_ms} ->
        :telemetry.execute([:xylon, :rtp, :egress], %{hold_us: max(0, due - now)}, %{kind: :video})
        :timer.sleep(delay_ms)

      :immediate ->
        :telemetry.execute([:xylon, :rtp, :egress], %{hold_us: 0}, %{kind: :video})
        :ok
    end

    send_us = System.monotonic_time(:microsecond)
    _ = forward_rtp(peer_ref, rtp_ssrc(packet), packet)
    EgressPace.put_after(pace, key, packet, send_us, catch_up?)
  end

  defp send_inline_one(_spec, pace), do: pace

  defp maybe_worker(state, index) do
    workers = Map.get(state, :send_workers, [])

    case Enum.at(workers, index) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {pid, state}
        else
          restart_worker_at(state, index)
        end

      nil ->
        restart_worker_at(state, index)

      _ ->
        {nil, state}
    end
  end

  defp restart_worker_at(state, index) do
    case SendWorker.start([]) do
      {:ok, new_pid} ->
        workers = List.replace_at(state.send_workers, index, new_pid)
        {new_pid, %{state | send_workers: workers}}

      {:error, reason} ->
        Logger.warning(
          "xylon send_worker restart failed session=#{inspect(state.session)} reason=#{inspect(reason)}"
        )

        {nil, state}
    end
  end

  defp retire_worker(state, worker) when is_pid(worker) do
    if Process.alive?(worker), do: Process.exit(worker, :kill)

    workers =
      Enum.map(state.send_workers, fn
        ^worker -> nil
        other -> other
      end)

    %{state | send_workers: workers}
  end

  defp send_worker_count(opts) do
    case Keyword.get(opts, :send_workers) || Application.get_env(:xylon, :send_workers) do
      n when is_integer(n) and n >= 1 ->
        n

      0 ->
        0

      _ ->
        min(8, System.schedulers_online())
    end
  end

  defp start_send_workers(n) when is_integer(n) and n >= 1 do
    for _ <- 1..n do
      {:ok, pid} = SendWorker.start([])
      pid
    end
  end

  defp start_send_workers(0), do: []

  defp stop_send_worker(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp stop_send_worker(_), do: :ok

  defp handle_media_rtcp(state, peer, rtcp) do
    case plan(state.session, peer) do
      {:ok, %{participant: participant}} ->
        case state.backend.handle_rtcp(participant, rtcp, state.backend_state) do
          {:ok, backend_state} -> %{state | backend_state: backend_state}
          {:error, _} -> state
        end

      :error ->
        state
    end
  end

  defp handle_media_dc(state, peer, channel_ref, data) do
    bytes = if is_binary(data), do: byte_size(data), else: -1
    profile? = profile_dc?()
    t0 = if profile?, do: System.monotonic_time(:microsecond), else: 0
    mb0 = if profile?, do: mailbox_len(self()), else: 0

    case plan(state.session, peer) do
      {:ok, %{participant: participant}} ->
        Logger.debug(
          "xylon dc in session=#{inspect(state.session)} from=#{inspect(participant.id)} bytes=#{bytes}"
        )

        case state.backend.handle_datachannel(
               participant,
               channel_ref,
               data,
               state.backend_state
             ) do
          {:forward_dc, specs, backend_state} ->
            send_dc_specs(specs, backend_state)

            if profile? do
              dt = System.monotonic_time(:microsecond) - t0
              maybe_log_dc_profile(dt, length(specs), mb0, mailbox_len(self()))
            end

            %{state | backend_state: backend_state}

          {:ok, backend_state} ->
            %{state | backend_state: backend_state}

          {:error, _} ->
            state
        end

      :error ->
        Logger.warning(
          "xylon dc in forwarder peer=#{inspect(peer)} bytes=#{bytes} -> no plan"
        )

        state
    end
  end

  defp profile_dc? do
    case System.get_env("XYLON_DC_PROFILE") do
      v when v in ["1", "true", "yes"] -> true
      _ -> false
    end
  end

  defp mailbox_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when is_integer(n) -> n
      _ -> -1
    end
  end

  # Sample ~1% to avoid log storms while still showing queue growth.
  defp maybe_log_dc_profile(dt_us, specs, mb_before, mb_after) do
    if :erlang.phash2({dt_us, mb_after}, 100) == 0 do
      Logger.warning(
        "xylon dc profile fwd_us=#{dt_us} specs=#{specs} mb_before=#{mb_before} mb_after=#{mb_after}"
      )
    end

    :ok
  end

  defp maybe_register_dc_open(state, peer, info) do
    backend = state.backend

    with true <- function_exported?(backend, :handle_datachannel_open, 3),
         {:ok, %{participant: participant}} <- plan_lookup(state.session, peer) do
      apply_dc_open(state, participant, info)
    else
      false ->
        state

      :error ->
        # Open raced ahead of put_plan; buffer until install_forward_plan.
        pending = Map.get(state, :pending_dc_opens, %{})
        %{state | pending_dc_opens: Map.put(pending, peer, info)}
    end
  end

  defp apply_dc_open(state, participant, info) do
    backend = state.backend

    case backend.handle_datachannel_open(participant, info, state.backend_state) do
      {:ok, backend_state} ->
        %{state | backend_state: backend_state}

      {:forward_dc, specs, backend_state} ->
        send_dc_specs(specs, backend_state)
        %{state | backend_state: backend_state}

      _ ->
        state
    end
  end

  defp plan(session, peer), do: plan_lookup(session, peer)

  defp forward_rtp(peer_ref, ssrc, packet) when is_pid(peer_ref) do
    case SendHandle.send_rtp(peer_ref, ssrc, packet) do
      :ok -> :ok
      {:error, _} -> Peer.send_rtp_async(peer_ref, ssrc, packet)
    end
  end
  defp rtp_ssrc(%{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  defp rtp_ssrc(_), do: 0

  defp relay(session, msg) when is_pid(session) do
    send(session, msg)
  end
end
