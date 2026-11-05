defmodule Xylon.Signaling.SIP.Transport do
  @moduledoc """
  XSIP transport adapter for outbound SIP on WebSocket connections.

  ## What problem this solves

  The [XSIP](https://github.com/Lazarus404/xsip) stack sends replies and in-dialog
  requests through a pluggable transport. WebSocket handlers are separate processes
  from the XSIP core, so this module looks up the handler pid in `ConnRegistry`
  and delivers outbound packets as `{:sip_out, packet}` messages.

  **Internal:** registered as the transport module for WebSocket `conn_id` values.
  Returns `{:error, :not_connected}` when the handler has terminated.

  ## RFCs and related specs

  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket transport
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP message delivery (via XSIP)
  """
  @behaviour XSIP.Transport

  alias Xylon.Signaling.SIP.ConnRegistry

  @doc """
  Delivers an outbound SIP packet to the WebSocket handler for `conn_id`.

  Returns `:ok` when the handler pid is registered, or `{:error, :not_connected}`.
  """
  @impl true
  def send_packet(conn_id, _peer, packet) when is_binary(packet) do
    case ConnRegistry.lookup(conn_id) do
      {:ok, pid} ->
        send(pid, {:sip_out, packet})
        :ok

      :error ->
        {:error, :not_connected}
    end
  end

  @doc "Returns the WebSocket connection id unchanged (XSIP transport identity)."
  @impl true
  def connection_id(conn_id), do: conn_id
end
