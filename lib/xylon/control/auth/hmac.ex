defmodule Xylon.Control.Auth.HMAC do
  @moduledoc """
  Mint and verify TTL-HMAC bearer tokens for Control auth.

  ## What problem this solves

  Operators without a JWT issuer still need signed, expiring credentials for
  inject and moderation APIs. HMAC tokens embed tenant, session, participant,
  and capabilities in a clear payload, signed with the tenant shared secret.
  Token shape: `base64url(payload).base64url(hmac-sha256)` where payload is
  `expiry_unix:tenant_id:session_id:participant_id:caps_json`.

  ## RFCs

  HMAC-SHA256 signing; no STUN/TURN/SIP RFC. Xylon control-plane API.

  ## Examples

      iex> ctx = %Xylon.Control.Context{
      ...>   tenant_id: "t1",
      ...>   session_id: "room",
      ...>   participant_id: "host",
      ...>   capabilities: ["inject"]
      ...> }
      iex> token = Xylon.Control.Auth.HMAC.mint(ctx, "lab-secret", ttl_sec: 300)
      iex> {:ok, got} = Xylon.Control.Auth.HMAC.verify(token, "lab-secret")
      iex> got.tenant_id
      "t1"
      iex> got.capabilities
      ["inject"]
  """

  alias Xylon.Control.Context

  @doc "Mints a bearer token for tests and lab tooling."
  @spec mint(Context.t(), binary(), keyword()) :: binary()
  def mint(%Context{} = ctx, secret, opts \\ [])
      when is_binary(secret) and secret != "" do
    ttl = Keyword.get(opts, :ttl_sec, 300)
    expiry = System.system_time(:second) + ttl
    caps = Jason.encode!(ctx.capabilities || [])
    payload = Enum.join([expiry, ctx.tenant_id, ctx.session_id, ctx.participant_id, caps], ":")
    mac = hmac(secret, payload)
    encode(payload) <> "." <> encode(mac)
  end

  @doc "Verifies a bearer token and returns a Context."
  @spec verify(binary(), binary(), keyword()) :: {:ok, Context.t()} | {:error, atom()}
  def verify(token, secret, opts \\ [])
      when is_binary(token) and is_binary(secret) and secret != "" do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with [p_b64, m_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- decode(p_b64),
         {:ok, mac} <- decode(m_b64),
         true <- secure_compare(hmac(secret, payload), mac),
         {:ok, ctx} <- parse_payload(payload),
         true <- ctx_expiry_ok?(payload, now) do
      {:ok, ctx}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Reads `tenant_id` from the clear payload without verifying the MAC.

  The value is untrusted until a subsequent `verify/2` succeeds.
  """
  @spec peek_tenant_id(binary()) :: {:ok, String.t()} | {:error, :unauthorized}
  def peek_tenant_id(token) when is_binary(token) do
    with [p_b64, _m_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- decode(p_b64),
         [_expiry, tenant, _session, _participant, _caps]
         when tenant != "" <- String.split(payload, ":", parts: 5) do
      {:ok, tenant}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp ctx_expiry_ok?(payload, now) do
    case Integer.parse(payload) do
      {expiry, _} when expiry >= now -> true
      _ -> false
    end
  end

  defp parse_payload(payload) do
    case String.split(payload, ":", parts: 5) do
      [_expiry, tenant, session, participant, caps_json]
      when tenant != "" and session != "" and participant != "" ->
        case Jason.decode(caps_json) do
          {:ok, caps} when is_list(caps) or is_map(caps) ->
            {:ok,
             %Context{
               tenant_id: tenant,
               session_id: session,
               participant_id: participant,
               capabilities: caps
             }}

          _ ->
            {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp hmac(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
  end

  defp encode(bin), do: Base.url_encode64(bin, padding: false)

  defp decode(bin) do
    case Base.url_decode64(bin, padding: false) do
      {:ok, _} = ok -> ok
      :error -> {:error, :unauthorized}
    end
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
