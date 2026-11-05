defmodule Xylon.Signaling.SIPApp do
  @moduledoc """
  XSIP application callback bridging SIP REGISTER/INVITE/BYE to `Xylon.Signaling`.

  ## What problem this solves

  Softphones and SIP-over-WebSocket clients speak RFC 3261 methods and carry
  SDP in INVITE bodies. This module implements `XSIP.App` so the [XSIP](https://github.com/Lazarus404/xsip)
  stack can accept lab REGISTER bindings, start echo sessions on INVITE, return
  SDP answers, and hang up on BYE or WebSocket disconnect (via `SessionBind`).

  Session id is derived from the To URI user part; tenant is fixed to `"lab"`.
  Registration contacts are stored in `Xylon.Signaling.SIP.Registrar` (open
  registrar, no digest authentication).

  **Internal:** configured as `:xsip, :app` from `Xylon.Application` when SIP
  is enabled. Not invoked directly by integrators.

  ## RFCs and related specs

  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP REGISTER, INVITE, BYE
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer in INVITE/200 (via [XSDP](https://github.com/Lazarus404/xsdp))
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket transport
  """
  @behaviour XSIP.App

  require Logger

  alias XSIP.Headers
  alias XSIP.Header.Type.{Contact, From, To}
  alias XSIP.Message
  alias Xylon.Signaling
  alias Xylon.Signaling.SIP.{Registrar, SessionBind}

  @lab_tenant "lab"

  @doc """
  Handles INVITE: starts a lab session, applies SDP offer, returns SDP answer.

  Rejects with 415 when Content-Type is not `application/sdp`, 488 when SDP is
  missing or session setup fails. Binds the WebSocket `conn_id` from `meta` on success.
  """
  @impl true
  def handle_invite(%Message{} = msg, _tx_ref, meta) do
    case invite_body(msg) do
      {:error, :not_sdp} ->
        {:reject, 415, "Unsupported Media Type"}

      {:error, :missing_sdp} ->
        {:reject, 488, "Not Acceptable Here"}

      {:ok, sdp} ->
        session_id = session_id_from(msg)
        _ = Signaling.hangup(@lab_tenant, session_id)

        with {:ok, _pid} <- Signaling.start_session(@lab_tenant, session_id),
             {:ok, answer} <- Signaling.apply_remote_offer(@lab_tenant, session_id, sdp) do
          bind_conn(meta, session_id)
          {:accept, answer}
        else
          {:error, reason} ->
            Logger.warning("xylon sip invite rejected: #{inspect(reason)}")
            {:reject, 488, "Not Acceptable Here"}
        end
    end
  end

  @doc """
  Handles REGISTER: stores or deletes Contact bindings in `Registrar`.

  Expires=0 or an empty Contact list removes the AOR binding.
  """
  @impl true
  def handle_register(%Message{} = msg, _meta) do
    aor = aor_from(msg)
    contacts = Headers.get(msg.headers, "contact")
    expires = expires_value(msg)

    cond do
      expires == 0 or contacts == [] ->
        Registrar.delete(aor)
        :ok

      true ->
        Registrar.put(aor, contacts)
        :ok
    end
  end

  @doc """
  Handles in-dialog requests. BYE hangs up the session derived from the To URI.
  """
  @impl true
  def handle_in_dialog(%Message{method: "BYE"} = msg, _dialog, _meta) do
    session_id = session_id_from(msg)
    _ = Signaling.hangup(@lab_tenant, session_id)
    :ok
  end

  def handle_in_dialog(_msg, _dialog, _meta), do: :ok

  @doc "XSIP transaction timeout hook; no lab-specific cleanup required."
  @impl true
  def handle_timeout(_tx, _meta), do: :ok

  defp invite_body(%Message{} = msg) do
    case Headers.get_one(msg.headers, "content-type") do
      %XSIP.Header.Type.ContentType{type: "application", subtype: "sdp"} ->
        if is_binary(msg.body) and msg.body != "", do: {:ok, msg.body}, else: {:error, :missing_sdp}

      nil ->
        {:error, :not_sdp}

      _ ->
        {:error, :not_sdp}
    end
  end

  defp bind_conn(%{conn: conn_id}, session_id) when is_binary(conn_id) do
    SessionBind.put(conn_id, @lab_tenant, session_id)
  end

  defp bind_conn(_meta, _session_id), do: :ok

  defp session_id_from(%Message{} = msg) do
    case Headers.get_one(msg.headers, "to") do
      %To{uri: uri} when is_binary(uri) -> user_from_uri(uri)
      _ -> "echo"
    end
  end

  defp user_from_uri(uri) do
    case Regex.run(~r/^sip:([^@;>]+)/i, uri) do
      [_, user] -> user
      _ -> "echo"
    end
  end

  defp aor_from(msg) do
    case Headers.get_one(msg.headers, "to") do
      %To{uri: uri} when is_binary(uri) ->
        uri

      _ ->
        case Headers.get_one(msg.headers, "from") do
          %From{uri: uri} when is_binary(uri) -> uri
          _ -> "sip:unknown@localhost"
        end
    end
  end

  defp expires_value(msg) do
    case Headers.get_one(msg.headers, "expires") do
      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {n, _} -> n
          :error -> contact_expires(msg, 3600)
        end

      %{value: n} when is_integer(n) ->
        n

      _ ->
        contact_expires(msg, 3600)
    end
  end

  defp contact_expires(msg, default) do
    case Headers.get_one(msg.headers, "contact") do
      %Contact{params: params} ->
        case Map.get(params, "expires") do
          v when is_binary(v) ->
            case Integer.parse(v) do
              {n, _} -> n
              :error -> default
            end

          n when is_integer(n) ->
            n

          _ ->
            default
        end

      _ ->
        default
    end
  end
end
