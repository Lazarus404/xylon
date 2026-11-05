defmodule Xylon.Control.History do
  @moduledoc """
  Short in-memory ring buffer of recent datachannel messages.

  ## What problem this solves

  Late joiners and REST/gRPC clients need recent chat or data messages without
  a separate message store. History appends inbound and server inject events
  per `{tenant_id, session_id, label}` with configurable count and byte caps.
  `tap_fun/2` plugs into backend publish taps for automatic recording.

  ## Internal

  ETS-backed GenServer; not durable across restarts.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  alias Xylon.Control.Auth

  @table :xylon_control_history

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Appends a message (async-safe; never raises to callers)."
  @spec append(term(), term(), binary(), term(), binary()) :: :ok
  def append(tenant_id, session_id, label, from, payload)
      when is_binary(label) and is_binary(payload) do
    ensure_table()
    key = {tenant_id, session_id, label}
    max_bytes = history_max_bytes()
    payload = if byte_size(payload) > max_bytes, do: binary_part(payload, 0, max_bytes), else: payload

    row = %{
      "ts" => System.system_time(:millisecond),
      "from" => from,
      "label" => label,
      "payload" => payload
    }

    list =
      case :ets.lookup(@table, key) do
        [{^key, rows}] -> [row | rows]
        [] -> [row]
      end

    :ets.insert(@table, {key, Enum.take(list, history_limit())})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Newest-first messages for a label."
  @spec list(term(), term(), binary()) :: [map()]
  def list(tenant_id, session_id, label) when is_binary(label) do
    ensure_table()

    case :ets.lookup(@table, {tenant_id, session_id, label}) do
      [{_, rows}] -> rows
      [] -> []
    end
  end

  @doc "Backend `:tap` fun that records inbound publish events."
  @spec tap_fun(term(), term()) :: (term() -> any())
  def tap_fun(tenant_id, session_id) do
    fn
      {:in, from, label, data} when is_binary(label) and is_binary(data) ->
        append(tenant_id, session_id, label, from, data)

      {:publish, _dest, label, payload} when is_binary(label) and is_binary(payload) ->
        append(tenant_id, session_id, label, "server", payload)

      _ ->
        :ok
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

  defp history_limit do
    case Keyword.get(Auth.config(), :history_limit, 100) do
      n when is_integer(n) and n > 0 -> n
      _ -> 100
    end
  end

  defp history_max_bytes do
    case Keyword.get(Auth.config(), :history_max_bytes, 4096) do
      n when is_integer(n) and n > 0 -> n
      _ -> 4096
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
