defmodule Xylon.Signaling.SIP.Registrar do
  @moduledoc """
  In-memory SIP registrar for lab REGISTER requests.

  ## What problem this solves

  SIP user agents send REGISTER to bind an address-of-record (AOR) to one or
  more Contact URIs so the server can route future requests. This GenServer
  stores AOR-to-contact mappings in memory for the echo lab. It accepts open
  registration (no digest authentication) and honors Expires=0 deregistration.

  **Internal:** updated by `Xylon.Signaling.SIPApp.handle_register/2`. Not
  a production-grade registrar; bindings are lost on restart.

  ## RFCs and related specs

  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- REGISTER binding semantics (Section 10)
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- registrations over WebSocket transport
  """
  use GenServer

  @doc """
  Starts the named Registrar GenServer.

  Called by the application supervisor; opts are reserved for future use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores Contact header values for address-of-record `aor`.

  Replaces any previous contacts for the same AOR. Returns `:ok`.
  """
  @spec put(String.t(), [term()]) :: :ok
  def put(aor, contacts) when is_binary(aor) and is_list(contacts) do
    GenServer.call(__MODULE__, {:put, aor, contacts})
  end

  @doc """
  Returns Contact bindings for `aor`, or `[]` when unregistered.
  """
  @spec get(String.t()) :: [term()]
  def get(aor) when is_binary(aor) do
    GenServer.call(__MODULE__, {:get, aor})
  end

  @doc """
  Removes all bindings for `aor` (REGISTER with Expires=0).

  Returns `:ok` whether or not the AOR existed.
  """
  @spec delete(String.t()) :: :ok
  def delete(aor) when is_binary(aor) do
    GenServer.call(__MODULE__, {:delete, aor})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, aor, contacts}, _from, state) do
    {:reply, :ok, Map.put(state, aor, contacts)}
  end

  def handle_call({:get, aor}, _from, state) do
    {:reply, Map.get(state, aor, []), state}
  end

  def handle_call({:delete, aor}, _from, state) do
    {:reply, :ok, Map.delete(state, aor)}
  end
end
