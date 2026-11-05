defmodule Xylon.Control.Audit do
  @moduledoc """
  Capped in-memory audit log for moderation actions.

  ## What problem this solves

  Operators need a recent trail of mute/ban/unmute/unban/kick events for support
  and compliance review without standing up external logging first. Audit
  appends rows per session with actor, target, reason, and timestamp; list is
  newest-first with a configurable cap.

  ## Internal

  ETS-backed GenServer; not durable across restarts.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  @table :xylon_control_audit
  @default_cap 500

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Appends an audit entry for a session."
  @spec append(term(), term(), map()) :: :ok
  def append(tenant_id, session_id, entry) when is_map(entry) do
    ensure_table()
    key = {tenant_id, session_id}
    row = Map.put(entry, :ts, System.system_time(:millisecond))

    list =
      case :ets.lookup(@table, key) do
        [{^key, rows}] -> [row | rows]
        [] -> [row]
      end

    :ets.insert(@table, {key, Enum.take(list, cap())})
    :ok
  end

  @doc "Returns newest-first audit rows for a session."
  @spec list(term(), term()) :: [map()]
  def list(tenant_id, session_id) do
    ensure_table()

    case :ets.lookup(@table, {tenant_id, session_id}) do
      [{_, rows}] -> rows
      [] -> []
    end
  end

  @doc "Test helper."
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

  defp cap do
    case Keyword.get(Xylon.Control.Auth.config(), :audit_cap, @default_cap) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_cap
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
