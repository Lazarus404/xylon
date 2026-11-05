defmodule Xylon.Signaling.SIP.SessionBind do
  @moduledoc """
  Tracks which media sessions belong to each SIP WebSocket connection.

  ## What problem this solves

  A single SIP-over-WebSocket connection can carry INVITE dialogs whose media
  runs in `Xylon.Session` processes keyed by `{tenant_id, session_id}`. When the
  WebSocket drops, those sessions must be hung up to avoid orphaned peers.
  This GenServer maps `conn_id` to session tuples so `WSHandler.terminate/2`
  can call `Xylon.Signaling.hangup/2` for each binding.

  **Internal:** started from `Xylon.Application` when SIP is enabled. Updated
  by `Xylon.Signaling.SIPApp` after a successful INVITE accept.

  ## RFCs and related specs

  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- WebSocket connection lifecycle
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP dialog teardown on transport loss
  """
  use GenServer

  @doc """
  Starts the named SessionBind GenServer.

  Called by the application supervisor; opts are reserved for future use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records that `conn_id` owns `{tenant_id, session_id}`.

  Duplicate tuples for the same connection are ignored. Returns `:ok`.
  """
  @spec put(String.t(), term(), term()) :: :ok
  def put(conn_id, tenant_id, session_id) do
    GenServer.call(__MODULE__, {:put, conn_id, tenant_id, session_id})
  end

  @doc """
  Returns all `{tenant_id, session_id}` tuples bound to `conn_id`.

  Returns `[]` when the connection has no bindings.
  """
  @spec list(String.t()) :: [{term(), term()}]
  def list(conn_id) do
    GenServer.call(__MODULE__, {:list, conn_id})
  end

  @doc """
  Removes and returns all session tuples for `conn_id`.

  Used on WebSocket terminate to hang up every session owned by the connection.
  """
  @spec take(String.t()) :: [{term(), term()}]
  def take(conn_id) do
    GenServer.call(__MODULE__, {:take, conn_id})
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:put, conn_id, tenant_id, session_id}, _from, state) do
    entry = {tenant_id, session_id}
    list = [entry | Map.get(state, conn_id, [])] |> Enum.uniq()
    {:reply, :ok, Map.put(state, conn_id, list)}
  end

  def handle_call({:list, conn_id}, _from, state) do
    {:reply, Map.get(state, conn_id, []), state}
  end

  def handle_call({:take, conn_id}, _from, state) do
    {list, state} = Map.pop(state, conn_id, [])
    {:reply, list, state}
  end
end
