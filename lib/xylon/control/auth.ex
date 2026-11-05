defmodule Xylon.Control.Auth do
  @moduledoc """
  Tenant authentication for Control HTTP, WebSocket, and gRPC routes.

  ## What problem this solves

  SaaS operators need to gate server-side inject, moderation, presence, and
  history APIs without trusting bare HTTP headers. Auth centralizes three modes:
  lab `x-tenant-id` trust, TTL-HMAC bearer tokens (minted or verified via
  `Secrets`), and JWT bearer verified against JWKS.   Successful auth yields a
  `Xylon.Control.Context` bound to tenant and session path parameters.
  For `:hmac` / `:jwt`, optional client-supplied `participant_id` must match
  the token identity (`bind_participant/2`); it never overrides the token.

  ## RFCs

  - [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519) -- JSON Web Token (JWT mode)
  - [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517) -- JSON Web Key Set (JWKS fetch)
  - TTL-HMAC bearer is a Xylon control-plane format (not an IETF media RFC)
  """

  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Context
  alias Xylon.Control.Secrets
  alias Xylon.Control.Secrets.Record

  @doc "Reads `config :xylon, :control` (default disabled / lab)."
  @spec config() :: keyword()
  def config do
    Application.get_env(:xylon, :control, [])
  end

  @doc "True when control routes and HMAC gating are enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "`:lab` (x-tenant-id), `:hmac` (bearer), or `:jwt` (JWKS bearer)."
  @spec auth_mode() :: :lab | :hmac | :jwt
  def auth_mode do
    case Keyword.get(config(), :auth, :lab) do
      :hmac -> :hmac
      :jwt -> :jwt
      _ -> :lab
    end
  end

  @doc "HMAC secret from config (required for Config secrets adapter / lab mint)."
  @spec hmac_secret() :: binary() | nil
  def hmac_secret do
    case Keyword.get(config(), :hmac_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  @doc """
  Builds a Context from Plug.Conn.

  Lab mode: `x-tenant-id` + optional body/query participant/session.
  HMAC mode: `Authorization: Bearer <token>`; tenant/session must match path/body.
  """
  @spec authenticate(Plug.Conn.t(), keyword()) ::
          {:ok, Context.t()} | {:error, :unauthorized | :forbidden}
  def authenticate(conn, opts \\ []) do
    expected_tenant = Keyword.get(opts, :tenant_id)
    expected_session = Keyword.get(opts, :session_id)

    case auth_mode() do
      :lab ->
        lab_context(conn, expected_tenant, expected_session, opts)

      :hmac ->
        hmac_context(conn, expected_tenant, expected_session)

      :jwt ->
        jwt_context(conn, expected_tenant, expected_session)
    end
  end

  @doc """
  Verifies an HMAC bearer using the configured Secrets adapter (dual-key).

  Options: `:now` (unix seconds) for tests.
  """
  @spec verify_hmac_token(binary(), keyword()) :: {:ok, Context.t()} | {:error, :unauthorized}
  def verify_hmac_token(token, opts \\ []) when is_binary(token) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, tenant_id} <- HMAC.peek_tenant_id(token),
         {:ok, %Record{} = rec} <- Secrets.get(tenant_id),
         {:ok, ctx} <- verify_with_record(token, rec, now) do
      {:ok, ctx}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Authenticates a raw Bearer token for non-Plug transports (gRPC).

  Lab mode is rejected (`:failed_precondition`). HMAC/JWT only.
  Options: `:tenant_id`, `:session_id` bind checks (same as REST path bind).
  """
  @spec authenticate_bearer(binary(), keyword()) ::
          {:ok, Context.t()} | {:error, :unauthorized | :forbidden | :failed_precondition}
  def authenticate_bearer(token, opts \\ [])

  def authenticate_bearer(token, opts) when is_binary(token) and token != "" do
    expected_tenant = Keyword.get(opts, :tenant_id)
    expected_session = Keyword.get(opts, :session_id)

    case auth_mode() do
      :lab ->
        {:error, :failed_precondition}

      :hmac ->
        with {:ok, ctx} <- verify_hmac_token(token),
             :ok <- bind_match(ctx.tenant_id, expected_tenant),
             :ok <- bind_match(ctx.session_id, expected_session) do
          {:ok, ctx}
        else
          {:error, :forbidden} -> {:error, :forbidden}
          _ -> {:error, :unauthorized}
        end

      :jwt ->
        with {:ok, ctx} <- Xylon.Control.Auth.JWT.verify(token),
             :ok <- bind_match(ctx.tenant_id, expected_tenant),
             :ok <- bind_match(ctx.session_id, expected_session) do
          {:ok, ctx}
        else
          {:error, :forbidden} -> {:error, :forbidden}
          _ -> {:error, :unauthorized}
        end
    end
  end

  def authenticate_bearer(_, _), do: {:error, :unauthorized}

  @doc """
  Builds a Backend `:authorize` fun from Control capabilities.

  For `:publish`, the fun reads `:capabilities` from the action meta (set on the
  participant at offer time). When meta omits `:capabilities` (lab / no Control
  context), publish is allowed. When present, requires list `"publish"` or map
  `publish: true`. Other actions allow unless `deny` is set on the create-time caps.
  """
  @spec backend_authorize(term()) :: (atom(), map() -> boolean())
  def backend_authorize(caps) do
    fn
      :publish, meta when is_map(meta) ->
        case Map.fetch(meta, :capabilities) do
          :error -> true
          {:ok, offer_caps} -> can_publish?(offer_caps)
        end

      _action, _meta ->
        not denied?(caps)
    end
  end

  @doc """
  Builds a 1-arity Backend `:authorize` fun for datachannel Sessions.

  Empty/missing capabilities allow (lab). Non-empty list requires `"send"` or
  `"send:<label>"` when meta `dir` is `:send` or `:publish`. Maps: `"send" => true`
  or `"send:<label>" => true`. Prefer `meta.capabilities` (participant join);
  fall back to create-time `caps`.
  """
  @spec datachannel_authorize(term()) :: (map() -> boolean())
  def datachannel_authorize(caps) do
    fn meta when is_map(meta) ->
      peer_caps =
        case Map.fetch(meta, :capabilities) do
          {:ok, offer_caps} -> offer_caps
          :error -> caps
        end

      case Map.get(meta, :dir) do
        dir when dir in [:send, :publish] ->
          can_send_label?(peer_caps, Map.get(meta, :label))

        _ ->
          not denied?(peer_caps)
      end
    end
  end

  defp can_publish?(caps) when is_list(caps), do: "publish" in caps

  defp can_publish?(caps) when is_map(caps) do
    Map.get(caps, "publish") == true or Map.get(caps, :publish) == true
  end

  defp can_publish?(_), do: false

  defp can_send_label?(caps, _label) when caps in [nil, [], %{}], do: true

  defp can_send_label?(caps, label) when is_list(caps) do
    "send" in caps or (is_binary(label) and ("send:" <> label) in caps)
  end

  defp can_send_label?(caps, label) when is_map(caps) do
    Map.get(caps, "send") == true or Map.get(caps, :send) == true or
      (is_binary(label) and Map.get(caps, "send:" <> label) == true)
  end

  defp can_send_label?(_, _), do: false

  defp denied?(%{"deny" => true}), do: true
  defp denied?(%{deny: true}), do: true
  defp denied?(_), do: false

  @doc """
  Asserts an optional client-supplied participant id matches the authenticated one.

  When `claimed` is nil or empty, returns `:ok` (caller keeps token identity).
  When present and not equal to `authenticated`, returns `{:error, :forbidden}`.
  Used for require_pvtid-style bind on Control WS join and HTTP signaling.
  """
  @spec bind_participant(binary(), term()) :: :ok | {:error, :forbidden}
  def bind_participant(authenticated, claimed)
      when is_binary(authenticated) and authenticated != "" do
    case claimed do
      nil -> :ok
      "" -> :ok
      ^authenticated -> :ok
      other when is_binary(other) -> {:error, :forbidden}
      _ -> :ok
    end
  end

  @doc "Mints an HMAC token when secret is configured."
  @spec mint(Context.t(), keyword()) :: {:ok, binary()} | {:error, :no_secret}
  def mint(%Context{} = ctx, opts \\ []) do
    case hmac_secret() do
      nil -> {:error, :no_secret}
      secret -> {:ok, HMAC.mint(ctx, secret, opts)}
    end
  end

  defp verify_with_record(token, %Record{} = rec, now) do
    case HMAC.verify(token, rec.current, now: now) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        if previous_usable?(rec, now) do
          HMAC.verify(token, rec.previous, now: now)
        else
          {:error, :unauthorized}
        end
    end
  end

  defp previous_usable?(%Record{previous: prev, previous_expires_at: exp}, now)
       when is_binary(prev) and prev != "" and is_integer(exp) and now < exp,
       do: true

  defp previous_usable?(_, _), do: false

  defp lab_context(conn, expected_tenant, expected_session, opts) do
    tenant =
      case Plug.Conn.get_req_header(conn, "x-tenant-id") do
        [t | _] when t != "" -> t
        _ -> nil
      end

    cond do
      is_nil(tenant) ->
        {:error, :unauthorized}

      is_binary(expected_tenant) and tenant != expected_tenant ->
        {:error, :forbidden}

      true ->
        session = expected_session || Keyword.get(opts, :default_session_id, "default")

        participant =
          case Keyword.get(opts, :participant_id) do
            id when is_binary(id) and id != "" -> id
            _ -> "p1"
          end

        {:ok,
         %Context{
           tenant_id: tenant,
           session_id: session,
           participant_id: participant,
           capabilities: Keyword.get(opts, :capabilities, [])
         }}
    end
  end

  defp hmac_context(conn, expected_tenant, expected_session) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, ctx} <- verify_hmac_token(token),
         :ok <- bind_match(ctx.tenant_id, expected_tenant),
         :ok <- bind_match(ctx.session_id, expected_session) do
      {:ok, ctx}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :unauthorized}
    end
  end

  defp jwt_context(conn, expected_tenant, expected_session) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, ctx} <- Xylon.Control.Auth.JWT.verify(token),
         :ok <- bind_match(ctx.tenant_id, expected_tenant),
         :ok <- bind_match(ctx.session_id, expected_session) do
      {:ok, ctx}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :unauthorized}
    end
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      ["bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      _ -> {:error, :unauthorized}
    end
  end

  defp bind_match(_actual, nil), do: :ok
  defp bind_match(actual, expected) when actual == expected, do: :ok
  defp bind_match(_, _), do: {:error, :forbidden}
end
