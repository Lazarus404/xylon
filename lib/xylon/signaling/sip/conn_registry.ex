defmodule Xylon.Signaling.SIP.ConnRegistry do
  @moduledoc """
  Registry from SIP WebSocket connection id to handler process.

  ## What problem this solves

  XSIP sends outbound SIP messages through `Xylon.Signaling.SIP.Transport`, but
  each live connection is a separate WebSock handler process. This GenServer
  stores `conn_id -> pid` mappings so transport `send_packet/3` can deliver
  frames to the correct handler. Process monitors remove stale entries when a
  handler exits without an explicit unregister.

  **Internal:** started from `Xylon.Application` when SIP is enabled. Handlers
  register on `init/1` and unregister on `terminate/2`.

  ## RFCs and related specs

  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket connections
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP message routing (via [XSIP](https://github.com/Lazarus404/xsip))
  """
  use GenServer

  @doc """
  Starts the named ConnRegistry GenServer.

  Called by the application supervisor; opts are reserved for future use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers WebSock handler `pid` for `conn_id`.

  Monitors `pid` so the registry entry is removed on crash. Returns `:ok`.
  """
  @spec register(String.t(), pid()) :: :ok
  def register(conn_id, pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, conn_id, pid})
  end

  @doc """
  Removes the registration for `conn_id`.

  Safe when `conn_id` is unknown. Returns `:ok`.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(conn_id) do
    GenServer.call(__MODULE__, {:unregister, conn_id})
  end

  @doc """
  Looks up the handler pid for `conn_id`.

  Returns `{:ok, pid}` or `:error` when no connection is registered.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(conn_id) do
    GenServer.call(__MODULE__, {:lookup, conn_id})
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:register, id, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, Map.put(state, id, pid) |> Map.put({:pid, pid}, id)}
  end

  def handle_call({:unregister, id}, _from, state) do
    state =
      case Map.pop(state, id) do
        {nil, state} -> state
        {pid, state} -> Map.delete(state, {:pid, pid})
      end

    {:reply, :ok, state}
  end

  def handle_call({:lookup, id}, _from, state) do
    {:reply, Map.fetch(state, id), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      case Map.pop(state, {:pid, pid}) do
        {nil, state} -> state
        {id, state} -> Map.delete(state, id)
      end

    {:noreply, state}
  end
end
