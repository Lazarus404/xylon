defmodule Xylon.Control.Quota do
  @moduledoc """
  Per-room join/inject rate limits and max participant caps.

  ## What problem this solves

  Multi-tenant hosts need edge protection against join storms and inject spam
  without pushing policy into every route handler. Quota keeps ETS counters per
  `{tenant_id, session_id}` for joins and injects per minute, plus
  `max_participants` before offer. Over limit returns `:rate_limited` and emits
  `quota.exceeded` webhooks.

  ## Internal

  GenServer supervises the quota ETS table; public checks are synchronous.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  alias Xylon.Control.Auth

  @table :xylon_control_quota

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Configured quota limits."
  @spec limits() :: map()
  def limits do
    case Keyword.get(Auth.config(), :quotas, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Checks and increments inject counter; returns `:ok` or `{:error, :rate_limited}`."
  @spec check_inject(term(), term()) :: :ok | {:error, :rate_limited}
  def check_inject(tenant_id, session_id) do
    limit = Map.get(limits(), :inject_per_minute) || Map.get(limits(), "inject_per_minute")

    if is_integer(limit) and limit > 0 do
      bump_minute(tenant_id, session_id, :inject, limit)
    else
      :ok
    end
  end

  @doc "Checks and increments join counter."
  @spec check_join(term(), term()) :: :ok | {:error, :rate_limited}
  def check_join(tenant_id, session_id) do
    limit = Map.get(limits(), :join_per_minute) || Map.get(limits(), "join_per_minute")

    if is_integer(limit) and limit > 0 do
      bump_minute(tenant_id, session_id, :join, limit)
    else
      :ok
    end
  end

  @doc """
  Join gate for WS/HTTP: no-op when Control/Quota is off; on limit emits
  `quota.exceeded` (`kind: join`) and returns `{:error, :rate_limited}`.
  """
  @spec gate_join(term(), term()) :: :ok | {:error, :rate_limited}
  def gate_join(tenant_id, session_id) do
    if Auth.enabled?() and is_pid(Process.whereis(__MODULE__)) do
      case check_join(tenant_id, session_id) do
        :ok ->
          :ok

        {:error, :rate_limited} = err ->
          emit_exceeded(tenant_id, session_id, "join")
          err
      end
    else
      :ok
    end
  end

  @doc "Checks max participants before join; `current_count` is existing size."
  @spec check_max_participants(term(), term(), non_neg_integer()) ::
          :ok | {:error, :rate_limited}
  def check_max_participants(_tenant_id, _session_id, current_count) do
    limit = Map.get(limits(), :max_participants) || Map.get(limits(), "max_participants")

    cond do
      not is_integer(limit) or limit <= 0 -> :ok
      current_count >= limit -> {:error, :rate_limited}
      true -> :ok
    end
  end

  @doc """
  Emits `quota.exceeded` webhook (`kind` is `inject` | `join` | `max_participants`).
  """
  @spec emit_exceeded(term(), term(), binary()) :: :ok
  def emit_exceeded(tenant_id, session_id, kind) when is_binary(kind) do
    Xylon.Control.Webhooks.emit("quota.exceeded", %{
      "tenant_id" => tenant_id,
      "session_id" => session_id,
      "kind" => kind
    })
  end

  @doc "Test helper: wipe counters."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp bump_minute(tenant_id, session_id, kind, limit) do
    ensure_table()
    minute = div(System.system_time(:second), 60)
    key = {tenant_id, session_id, kind, minute}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count > limit do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

      _ ->
        @table
    end
  end
end
