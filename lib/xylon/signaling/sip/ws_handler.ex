defmodule Xylon.Signaling.SIP.WSHandler do
  @moduledoc """
  WebSocket handler for RFC 7118 SIP-over-WebSocket framing.

  ## What problem this solves

  SIP user agents expect a bidirectional byte stream where each WebSocket text
  or binary frame carries one complete SIP message. This handler registers the
  connection in `ConnRegistry`, forwards inbound frames to `XSIP.incoming/4` via
  `Transport`, and pushes outbound `{:sip_out, packet}` messages back to the client.
  On disconnect it hangs up all sessions bound to the connection via `SessionBind`.

  **Internal:** upgraded from `GET /sip` in `Xylon.Signaling.HTTP`. One handler
  process per WebSocket connection.

  ## RFCs and related specs

  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket (one message per frame)
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP message semantics (via [XSIP](https://github.com/Lazarus404/xsip))
  """
  @behaviour WebSock

  alias Xylon.Signaling
  alias Xylon.Signaling.SIP.{ConnRegistry, SessionBind, Transport}

  @impl true
  def init(opts) do
    conn_id = Keyword.fetch!(opts, :conn_id)
    peer = Keyword.get(opts, :peer, {:ws, conn_id})
    :ok = ConnRegistry.register(conn_id, self())
    {:ok, %{conn_id: conn_id, peer: peer}}
  end

  @impl true
  def handle_in({data, opcode: opcode}, state) when opcode in [:text, :binary] do
    raw = IO.iodata_to_binary(data)
    :ok = XSIP.incoming(raw, Transport, state.conn_id, state.peer)
    {:ok, state}
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:sip_out, packet}, state) when is_binary(packet) do
    {:push, {:text, packet}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(SessionBind.take(state.conn_id), fn {tenant_id, session_id} ->
      _ = Signaling.hangup(tenant_id, session_id)
    end)

    _ = ConnRegistry.unregister(state.conn_id)
    :ok
  end
end
