defmodule Xylon.Recording.Aggregator do
  @moduledoc """
  Coordinates multi-home recording segment reports into one webhook.

  ## What problem this solves

  Dual-edge rooms finalize stems on each hub. Control must receive a single
  `recording.completed` per segment after every expected edge reports (or after
  a force-flush / timeout). This GenServer holds in-flight segments on the
  coordinator node only; media never crosses Erlang distribution.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon multi-home recording aggregation.
  """

  use GenServer

  @typedoc "Segment begin fields stored until emit."
  @type begin_info :: %{
          required(:recording_id) => binary(),
          required(:tenant_id) => term(),
          required(:session_id) => term(),
          required(:sequence) => non_neg_integer(),
          required(:preceded_by) => binary() | nil,
          required(:mode) => binary(),
          required(:started_at) => integer(),
          required(:expected_edges) => [binary()]
        }

  @typedoc "Per-edge finalize report."
  @type edge_report :: %{
          required(:edge_node) => binary(),
          optional(:artifacts) => [map()],
          optional(:counters) => map(),
          optional(:error) => binary() | nil,
          optional(:had_local_publishers) => boolean()
        }

  @doc "Starts the aggregator (named)."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Clears all in-flight segments (tests)."
  @spec reset!() :: :ok
  def reset! do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :reset)
    end
  end

  @doc """
  Registers a multi-home segment on the coordinator.

  `expected_edges` are candidate edge nodes that started the segment. Idle
  edges report empty (`had_local_publishers: false`) and unblock await; only
  candidates that never report count toward `edges_missing` on flush.
  """
  @spec begin_segment(begin_info()) :: :ok | {:error, term()}
  def begin_segment(info) when is_map(info) do
    GenServer.call(__MODULE__, {:begin, info})
  end

  @doc """
  Adds late-joining cohost edges to the candidate set (mid-segment trunk).
  """
  @spec add_expected_edges(binary(), [binary() | node()]) :: :ok | {:error, term()}
  def add_expected_edges(recording_id, edges)
      when is_binary(recording_id) and is_list(edges) do
    GenServer.call(__MODULE__, {:add_expected, recording_id, edges})
  end

  @doc "Merges one edge finalize report into the segment."
  @spec report_edge(binary(), edge_report()) :: :ok | {:error, term()}
  def report_edge(recording_id, report)
      when is_binary(recording_id) and is_map(report) do
    GenServer.call(__MODULE__, {:report, recording_id, report})
  end

  @doc """
  Waits until all expected edges report, then emits once.

  On timeout, force-flushes with whatever reports arrived (`edges_missing`).
  """
  @spec await_or_flush(binary(), non_neg_integer()) :: :ok | {:error, term()}
  def await_or_flush(recording_id, timeout_ms)
      when is_binary(recording_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(__MODULE__, {:await, recording_id, timeout_ms}, timeout_ms + 5_000)
  end

  @doc "Emits immediately with arrived reports and `edges_missing`."
  @spec force_flush(binary()) :: :ok | {:error, term()}
  def force_flush(recording_id) when is_binary(recording_id) do
    GenServer.call(__MODULE__, {:force_flush, recording_id})
  end

  @impl true
  def init(_) do
    {:ok, %{segments: %{}}}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{segments: %{}}}
  end

  def handle_call({:begin, info}, _from, state) do
    rid = Map.fetch!(info, :recording_id)

    case Map.get(state.segments, rid) do
      nil ->
        expected =
          info
          |> Map.fetch!(:expected_edges)
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        seg = %{
          tenant_id: Map.fetch!(info, :tenant_id),
          session_id: Map.fetch!(info, :session_id),
          sequence: Map.fetch!(info, :sequence),
          preceded_by: Map.get(info, :preceded_by),
          mode: Map.fetch!(info, :mode),
          started_at: Map.fetch!(info, :started_at),
          expected: expected,
          reports: %{},
          waiters: [],
          emitted?: false,
          await_timer: nil
        }

        {:reply, :ok, put_in(state.segments[rid], seg)}

      _ ->
        {:reply, {:error, :already_begun}, state}
    end
  end

  def handle_call({:add_expected, rid, edges}, _from, state) do
    case Map.get(state.segments, rid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{emitted?: true} ->
        {:reply, :ok, state}

      seg ->
        added = edges |> Enum.map(&to_string/1) |> MapSet.new()
        seg = %{seg | expected: MapSet.union(seg.expected, added)}
        {:reply, :ok, put_in(state.segments[rid], seg)}
    end
  end

  def handle_call({:report, rid, report}, _from, state) do
    case Map.get(state.segments, rid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{emitted?: true} ->
        {:reply, :ok, state}

      seg ->
        edge = report |> Map.fetch!(:edge_node) |> to_string()
        seg = put_in(seg.reports[edge], normalize_report(report, edge))
        state = put_in(state.segments[rid], seg)
        {:reply, :ok, maybe_complete(rid, state)}
    end
  end

  def handle_call({:await, rid, timeout_ms}, from, state) do
    case Map.get(state.segments, rid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{emitted?: true} ->
        {:reply, :ok, state}

      seg ->
        if complete?(seg) do
          state = emit_and_drop(rid, state)
          {:reply, :ok, state}
        else
          timer = Process.send_after(self(), {:await_timeout, rid}, timeout_ms)
          seg = %{seg | waiters: [from | seg.waiters], await_timer: timer}
          {:noreply, put_in(state.segments[rid], seg)}
        end
    end
  end

  def handle_call({:force_flush, rid}, _from, state) do
    case Map.get(state.segments, rid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{emitted?: true} ->
        {:reply, :ok, state}

      _seg ->
        {:reply, :ok, emit_and_drop(rid, state)}
    end
  end

  @impl true
  def handle_info({:await_timeout, rid}, state) do
    case Map.get(state.segments, rid) do
      nil ->
        {:noreply, state}

      %{emitted?: true} ->
        {:noreply, state}

      _ ->
        {:noreply, emit_and_drop(rid, state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp normalize_report(report, edge) do
    artifacts = List.wrap(Map.get(report, :artifacts) || Map.get(report, "artifacts") || [])

    had_local =
      case Map.get(report, :had_local_publishers) || Map.get(report, "had_local_publishers") do
        true -> true
        false -> false
        _ -> artifacts != []
      end

    %{
      edge_node: edge,
      artifacts: artifacts,
      counters: Map.get(report, :counters) || Map.get(report, "counters") || %{},
      error: Map.get(report, :error) || Map.get(report, "error"),
      had_local_publishers: had_local
    }
  end

  defp complete?(seg) do
    # Idle candidates unblock by sending an empty report; await does not require
    # capture. Missing candidates after timeout appear as edges_missing.
    Enum.all?(seg.expected, &Map.has_key?(seg.reports, &1))
  end

  defp maybe_complete(rid, state) do
    seg = Map.fetch!(state.segments, rid)

    if complete?(seg) and seg.waiters != [] do
      emit_and_drop(rid, state)
    else
      state
    end
  end

  defp emit_and_drop(rid, state) do
    seg = Map.fetch!(state.segments, rid)

    if seg.await_timer do
      _ = Process.cancel_timer(seg.await_timer)
    end

    unless seg.emitted? do
      do_emit(rid, seg)
    end

    Enum.each(seg.waiters, fn from -> GenServer.reply(from, :ok) end)
    %{state | segments: Map.delete(state.segments, rid)}
  end

  defp do_emit(rid, seg) do
    ended_at = System.system_time(:millisecond)
    reports = Map.values(seg.reports)
    artifacts = Enum.flat_map(reports, & &1.artifacts)
    counters = merge_counters(seg.reports)

    # edges_missing: candidates that never reported (capture or idle).
    # Idle reporters are not missing; they sent empty reports.
    missing = Enum.count(seg.expected, &(not Map.has_key?(seg.reports, &1)))
    idle = Enum.count(reports, fn r -> r.had_local_publishers != true and r.artifacts == [] end)

    counters =
      counters
      |> Map.put("edges_missing", missing)
      |> Map.put("edges_idle", idle)

    payload = %{
      "tenant_id" => to_string(seg.tenant_id),
      "session_id" => to_string(seg.session_id),
      "recording_id" => rid,
      "sequence" => seg.sequence,
      "preceded_by" => seg.preceded_by,
      "mode" => seg.mode,
      "started_at" => seg.started_at,
      "ended_at" => ended_at,
      "artifacts" => artifacts,
      "counters" => counters
    }

    Xylon.Control.Webhooks.emit("recording.completed", payload)
  end

  defp merge_counters(reports) do
    reports
    |> Map.values()
    |> Enum.reduce(%{}, fn %{counters: c}, acc ->
      Enum.reduce(stringify_keys(c), acc, fn {k, v}, a ->
        cond do
          is_integer(v) and is_integer(Map.get(a, k)) -> Map.put(a, k, Map.get(a, k) + v)
          is_integer(v) and not Map.has_key?(a, k) -> Map.put(a, k, v)
          true -> Map.put_new(a, k, v)
        end
      end)
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end
end
