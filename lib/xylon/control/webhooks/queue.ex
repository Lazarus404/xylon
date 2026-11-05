defmodule Xylon.Control.Webhooks.Queue do
  @moduledoc """
  Async webhook delivery with DETS-backed dead-letter queue.

  ## What problem this solves

  Transient webhook outages should not drop inject or quota events. Queue runs
  live delivery in a Task (three quick retries via `Delivery`), persists
  failures to DETS, and drains on an interval with longer backoff until
  success, cap eviction, or `webhook_dlq_max_attempts`.

  ## Internal

  GenServer owns DETS open/close and the drain timer.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """
  use GenServer

  require Logger

  alias Xylon.Control.Auth
  alias Xylon.Control.Webhooks.Delivery

  @table :xylon_control_webhook_dlq
  @default_max 1000
  @default_interval_ms 5_000
  @default_max_attempts 20
  # Seconds until next drain attempt after DLQ try n (0-based).
  @dlq_backoff_s [5, 30, 120, 300, 900, 3600]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedules async live delivery (3 retries). On failure, enqueues to DETS.

  Returns `:ok` immediately. No-op cast if this process is not running.
  """
  @spec deliver_async(binary(), map()) :: :ok
  def deliver_async(type, payload) when is_binary(type) and is_map(payload) do
    case Process.whereis(__MODULE__) do
      nil ->
        Task.start(fn -> _ = Delivery.deliver(type, payload) end)
        :ok

      _pid ->
        GenServer.cast(__MODULE__, {:deliver_async, type, payload})
    end
  end

  @doc "Persists a failed webhook for later drain. No-op if Queue is down."
  @spec enqueue_after_failure(binary(), map()) :: :ok
  def enqueue_after_failure(type, payload) when is_binary(type) and is_map(payload) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:enqueue, type, payload})
    end
  end

  @doc "Drains due rows once (also invoked on the interval timer)."
  @spec drain() :: :ok
  def drain do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :drain, 30_000)
    end
  end

  @doc "Newest-first list of pending DLQ rows (maps)."
  @spec list() :: [map()]
  def list do
    case Process.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :list)
    end
  end

  @doc "Returns `{count, max_entries}`."
  @spec stats() :: {non_neg_integer(), pos_integer()}
  def stats do
    case Process.whereis(__MODULE__) do
      nil -> {0, @default_max}
      _pid -> GenServer.call(__MODULE__, :stats)
    end
  end

  @doc "Deletes all DLQ rows (tests)."
  @spec flush!() :: :ok
  def flush! do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :flush)
    end
  end

  @impl true
  def init(_opts) do
    path = dlq_path()
    warn_temp_dlq(path)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set, keypos: 1) do
      {:ok, _} ->
        state = %{
          path: path,
          max: dlq_max(),
          max_attempts: dlq_max_attempts(),
          interval_ms: dlq_interval_ms()
        }

        _ = schedule_drain(state.interval_ms)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :dets.close(@table)
    :ok
  end

  @impl true
  def handle_cast({:deliver_async, type, payload}, state) do
    parent = self()

    _ =
      Task.start(fn ->
        case Delivery.deliver(type, payload) do
          :ok ->
            :ok

          {:error, _} ->
            GenServer.cast(parent, {:enqueue_from_task, type, payload})
        end
      end)

    {:noreply, state}
  end

  def handle_cast({:enqueue_from_task, type, payload}, state) do
    _ = do_enqueue(type, payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:enqueue, type, payload}, _from, state) do
    :ok = do_enqueue(type, payload, state)
    {:reply, :ok, state}
  end

  def handle_call(:drain, _from, state) do
    :ok = do_drain(state)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, list_rows(), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, {:dets.info(@table, :size), state.max}, state}
  end

  def handle_call(:flush, _from, state) do
    :ok = :dets.delete_all_objects(@table)
    _ = :dets.sync(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    _ = do_drain(state)
    _ = schedule_drain(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_enqueue(type, payload, state) do
    now = now_ms()
    id = unique_id()

    row = %{
      id: id,
      type: type,
      payload: payload,
      attempts: 0,
      enqueued_at: now,
      next_at: now,
      last_error: nil
    }

    :ok = :dets.insert(@table, {id, row})
    enforce_cap(state.max)
    _ = :dets.sync(@table)
    :ok
  end

  defp do_drain(state) do
    now = now_ms()

    @table
    |> :dets.match({:"$1", :"$2"})
    |> Enum.each(fn [id, row] ->
      if row.next_at <= now do
        drain_row(id, row, state)
      end
    end)

    _ = :dets.sync(@table)
    :ok
  end

  defp drain_row(id, row, state) do
    case Delivery.post_once(row.type, row.payload) do
      :ok ->
        :dets.delete(@table, id)

      {:error, reason} ->
        attempts = row.attempts + 1

        if attempts >= state.max_attempts do
          Logger.warning(
            "xylon control webhook DLQ dropped type=#{row.type} attempts=#{attempts} error=#{inspect(reason)}"
          )

          :dets.delete(@table, id)
        else
          updated = %{
            row
            | attempts: attempts,
              next_at: now_ms() + backoff_ms(attempts),
              last_error: truncate_error(reason)
          }

          :ok = :dets.insert(@table, {id, updated})
        end
    end
  end

  defp enforce_cap(max) when is_integer(max) and max > 0 do
    size = :dets.info(@table, :size)

    if size > max do
      overflow = size - max

      @table
      |> :dets.match({:"$1", :"$2"})
      |> Enum.map(fn [id, row] -> {row.enqueued_at, id} end)
      |> Enum.sort()
      |> Enum.take(overflow)
      |> Enum.each(fn {_ts, id} ->
        Logger.warning("xylon control webhook DLQ cap eviction id=#{id}")
        :dets.delete(@table, id)
      end)
    end

    :ok
  end

  defp list_rows do
    @table
    |> :dets.match({:"$1", :"$2"})
    |> Enum.map(fn [_id, row] -> row end)
    |> Enum.sort_by(& &1.enqueued_at, :desc)
  end

  defp schedule_drain(interval_ms) do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp backoff_ms(attempts) when attempts >= 1 do
    idx = min(attempts - 1, length(@dlq_backoff_s) - 1)
    Enum.at(@dlq_backoff_s, idx) * 1000
  end

  defp truncate_error(reason) do
    reason |> inspect() |> String.slice(0, 200)
  end

  defp unique_id do
    Integer.to_string(System.unique_integer([:positive])) <> "-" <>
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp warn_temp_dlq(path) do
    cfg = Auth.config()
    url = Keyword.get(cfg, :webhook_url)
    configured = Keyword.get(cfg, :webhook_dlq_path)

    if is_binary(url) and url != "" and (not is_binary(configured) or configured == "") do
      Logger.warning(
        "xylon control webhook DLQ using temp path=#{path}; set webhook_dlq_path or XYLON_CONTROL_WEBHOOK_DLQ_PATH for durable storage"
      )
    end

    :ok
  end

  defp dlq_path do
    case Keyword.get(Auth.config(), :webhook_dlq_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Path.join(System.tmp_dir!(), "xylon_webhook_dlq.dets")
    end
  end

  defp dlq_max do
    case Keyword.get(Auth.config(), :webhook_dlq_max) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max
    end
  end

  defp dlq_max_attempts do
    case Keyword.get(Auth.config(), :webhook_dlq_max_attempts) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_attempts
    end
  end

  defp dlq_interval_ms do
    case Keyword.get(Auth.config(), :webhook_dlq_interval_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_interval_ms
    end
  end
end
