defmodule Xylon.Signaling.HTTP do
  @moduledoc """
  Lab HTTP signaling router for JSEP session lifecycle and optional SIP WebSocket upgrade.

  ## What problem this solves

  Browser and curl clients need REST endpoints to create a tenant session, post
  SDP offers, manage subscribe/switch routes, and leave participants without
  holding a persistent WebSocket. This Plug router exposes those JSEP operations
  and serves the lab test client static files. It also upgrades `GET /sip` to
  RFC 7118 SIP-over-WebSocket when SIP is enabled.

  Auth is gateway-trust by default (`x-tenant-id` header). When
  `config :xylon, control: [enabled: true, auth: :hmac]`, create/offer/inject
  require a TTL-HMAC bearer instead. Under `:hmac` / `:jwt`, optional query
  `participant_id` must match the token (require_pvtid-style); it does not
  override the token. Control-only routes (presence, history,
  moderate, data inject, record, control WebSocket) return 404 when control is disabled.

  **Internal:** started as a Bandit child from `Xylon.Application`; not called
  directly by integrators. Use HTTP paths documented below or
  `Xylon.Signaling.WSHandler` for the control WebSocket.

  ## HTTP API (JSEP)

  - `POST /v1/sessions` -- create session (JSON body: `session_id`, optional `library`, `backend_opts`)
  - `POST /v1/sessions/:id/offer` -- post SDP offer; response is `application/sdp` answer
  - `POST /v1/sessions/:id/subscribe|unsubscribe|switch|set_substream|unpublish|update` -- backend routing (JSON body)
  - `DELETE /v1/sessions/:id/participants/:participant_id` -- remove one participant
  - `GET /place` -- placement helper JSON (`tenant_id`, `session_id`, optional `region_hint`, `multi_home`)
  - `GET /v1/tenants/:tid/fleet/summary|nodes` -- Control fleet load (when control enabled)
  - `POST /v1/tenants/:tid/fleet/accepting` -- Control drain/undrain (`{"node","accepting"}`)
  - `GET /sip` -- WebSocket upgrade to `Xylon.Signaling.SIP.WSHandler` (subprotocol `sip`)

  ## RFCs and related specs

  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) -- JSEP offer/answer over HTTP
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via [XSDP](https://github.com/Lazarus404/xsdp))
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket upgrade at `/sip`
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP dialog semantics (via [XSIP](https://github.com/Lazarus404/xsip))
  """
  use Plug.Router

  alias Xylon.Control.Auth
  alias Xylon.Control.Context
  alias Xylon.Control.Router, as: ControlRouter
  alias Xylon.Signaling

  plug :match
  plug :fetch_query_params
  plug :dispatch

  @doc false
  def init(opts), do: opts

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/place" do
    tenant = conn.query_params["tenant_id"] || conn_tenant(conn)
    session = conn.query_params["session_id"]
    region = conn.query_params["region_hint"]
    multi? = conn.query_params["multi_home"] in ["1", "true", "yes"]

    cond do
      is_nil(tenant) or tenant == "" or is_nil(session) or session == "" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "tenant_id and session_id required"}))

      true ->
        opts =
          [
            tenant_id: tenant,
            session_id: session,
            multi_home: multi?
          ]
          |> then(fn o ->
            if is_binary(region) and region != "", do: Keyword.put(o, :region_hint, region), else: o
          end)
          |> then(fn o ->
            urls = Application.get_env(:xylon, :cluster, []) |> Keyword.get(:edge_urls, %{})
            Keyword.put(o, :edge_urls, stringify_keys(urls))
          end)

        case Xylon.Cluster.Placement.recommend(opts) do
          {:ok, place} ->
            body =
              Jason.encode!(%{
                edge_url: place.edge_url,
                node: Atom.to_string(place.node),
                region_id: place.region_id,
                role: place.role
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(503, Jason.encode!(%{error: inspect(reason)}))
        end
    end
  end

  get "/favicon.ico" do
    send_resp(conn, 204, "")
  end

  get "/" do
    send_client_index(conn)
  end

  get "/client" do
    send_client_index(conn)
  end

  get "/client/*path" do
    rel =
      case path do
        list when is_list(list) -> Path.join(list)
        bin when is_binary(bin) -> bin
        _ -> ""
      end

    if rel in ["", ".", "index.html"] do
      send_client_index(conn)
    else
      send_client_file(conn, rel)
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/data" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.inject(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/dest/resolve" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.resolve_dest(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/moderate" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.moderate(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/record/start" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.record_start(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/record/stop" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.record_stop(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions/:sid/record" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.record_get(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.sessions_list(conn, tid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/fleet/summary" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.fleet_summary(conn, tid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/fleet/nodes" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.fleet_nodes(conn, tid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/fleet/accepting" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.fleet_accepting(conn, tid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions/:sid/presence" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.presence(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions/:sid/history" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.history(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions/:sid/groups" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.groups_list(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/groups" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.groups_create(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  delete "/v1/tenants/:tid/sessions/:sid/groups/:gid" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.groups_delete(conn, tid, sid, gid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/tenants/:tid/sessions/:sid/groups/:gid/members" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.groups_add_member(conn, tid, sid, gid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  delete "/v1/tenants/:tid/sessions/:sid/groups/:gid/members/:pid" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.groups_remove_member(conn, tid, sid, gid, pid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/tenants/:tid/sessions/:sid/routes" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.routes_list(conn, tid, sid)
    else
      send_resp(conn, 404, "not found")
    end
  end

  put "/v1/tenants/:tid/sessions/:sid/routes/:sender_id" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.routes_put(conn, tid, sid, sender_id)
    else
      send_resp(conn, 404, "not found")
    end
  end

  delete "/v1/tenants/:tid/sessions/:sid/routes/:sender_id" do
    if Xylon.Control.Auth.enabled?() do
      ControlRouter.routes_delete(conn, tid, sid, sender_id)
    else
      send_resp(conn, 404, "not found")
    end
  end

  get "/v1/ws" do
    if Xylon.Control.Auth.enabled?() do
      upgrade_control_ws(conn)
    else
      send_resp(conn, 404, "not found")
    end
  end

  post "/v1/sessions" do
    with {:ok, tenant_id, ctx, conn} <- ControlRouter.require_tenant(conn),
         {:ok, body, conn} <- read_body(conn),
         {:ok, params} <- decode_json(body),
         {:ok, session_id} <- fetch_string(params, "session_id"),
         :ok <- bind_session(ctx, session_id),
         :ok <- Xylon.Control.Quota.gate_join(tenant_id, session_id),
         {:ok, library} <- fetch_library(params),
         {:ok, backend_opts} <- fetch_backend_opts(params),
         backend_opts <- maybe_authorize_opts(backend_opts, ctx, library) do
      case Signaling.start_session(tenant_id, session_id, library, backend_opts) do
        {:ok, _pid} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, Jason.encode!(%{session_id: session_id, library: library}))

        {:error, :already_exists} ->
          send_resp(conn, 409, "session exists")

        {:error, :not_accepting} ->
          send_resp(conn, 503, "node not accepting")

        {:error, :not_attached} ->
          send_resp(conn, 400, "library not attached")

        {:error, reason} ->
          send_resp(conn, 500, "create failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :rate_limited} ->
        send_resp(conn, 429, "rate limited")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :missing_session_id} ->
        send_resp(conn, 400, "missing session_id")

      {:error, :missing_library} ->
        send_resp(conn, 400, "missing library")

      {:error, :unknown_library} ->
        send_resp(conn, 400, "unknown library")

      {:error, :bad_backend_opts} ->
        send_resp(conn, 400, "invalid backend_opts")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  post "/v1/sessions/:id/offer" do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: id),
         {:ok, offer, conn} <- read_body(conn),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, id, ctx),
         :ok <- ban_gate(tenant_id, id, offer_opts) do
      case Signaling.apply_remote_offer(tenant_id, id, offer, offer_opts) do
        {:ok, answer} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_content_type("application/sdp")
          |> send_resp(200, answer)

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :participant_exists} ->
          send_resp(conn, 409, "participant exists")

        {:error, :forbidden} ->
          send_resp(conn, 403, "forbidden")

        {:error, reason} ->
          send_resp(conn, 500, "offer failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  post "/v1/sessions/:id/subscribe" do
    subscribe_http(conn, id, :subscribe)
  end

  post "/v1/sessions/:id/unsubscribe" do
    subscribe_http(conn, id, :unsubscribe)
  end

  post "/v1/sessions/:id/switch" do
    switch_http(conn, id)
  end

  post "/v1/sessions/:id/set_substream" do
    set_substream_http(conn, id)
  end

  post "/v1/sessions/:id/unpublish" do
    unpublish_http(conn, id)
  end

  post "/v1/sessions/:id/update" do
    update_http(conn, id)
  end

  delete "/v1/sessions/:id/participants/:participant_id" do
    with {:ok, tenant_id, _ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: id) do
      case Signaling.leave(tenant_id, id, participant_id) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")
    end
  end

  match "/sip" do
    if conn.method == "GET" do
      upgrade_sip(conn)
    else
      send_resp(conn, 405, "method not allowed")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp auth_error_message do
    if Xylon.Control.Auth.enabled?() and Xylon.Control.Auth.auth_mode() in [:hmac, :jwt] do
      "missing or invalid bearer token"
    else
      "missing x-tenant-id"
    end
  end

  defp conn_tenant(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tid | _] when is_binary(tid) and tid != "" -> tid
      _ -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp bind_session(nil, _session_id), do: :ok

  defp bind_session(%Xylon.Control.Context{session_id: bound}, session_id)
       when bound == session_id,
       do: :ok

  defp bind_session(%Xylon.Control.Context{}, _session_id), do: {:error, :forbidden}

  defp maybe_authorize_opts(backend_opts, nil, _library), do: backend_opts

  defp maybe_authorize_opts(backend_opts, %Context{} = ctx, library) do
    fun =
      if library == :datachannel do
        Auth.datachannel_authorize(ctx.capabilities)
      else
        Auth.backend_authorize(ctx.capabilities)
      end

    Keyword.put(backend_opts, :authorize, fun)
  end

  defp upgrade_sip(conn) do
    protocols =
      conn
      |> get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)

    conn =
      if "sip" in protocols do
        put_resp_header(conn, "sec-websocket-protocol", "sip")
      else
        conn
      end

    conn_id = "ws-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    peer = {:ws, remote_peer(conn)}

    conn
    |> WebSockAdapter.upgrade(
      Xylon.Signaling.SIP.WSHandler,
      [conn_id: conn_id, peer: peer],
      timeout: 60_000
    )
    |> halt()
  end

  defp remote_peer(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) -> {ip, conn.port}
      _ -> :unknown
    end
  end

  defp send_client_index(conn) do
    send_client_file(conn, "index.html")
  end

  defp send_client_file(conn, rel) do
    rel = String.replace(rel, ~r/\A\/+/, "")

    case resolve_client_path(rel) do
      {:ok, path} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type(content_type(path))
        |> send_file(200, path)

      :error ->
        send_resp(conn, 404, "not found")
    end
  end

  defp resolve_client_path(rel) do
    roots = [
      Path.expand("../../../../xylon-test-client/dist", __DIR__),
      Path.expand("../../../../xylon-test-client", __DIR__),
      Path.join(:code.priv_dir(:xylon), "echo")
    ]

    Enum.find_value(roots, :error, fn root ->
      path = Path.join(root, rel)
      if File.regular?(path), do: {:ok, path}
    end)
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".js" -> "application/javascript"
      ".css" -> "text/css"
      ".html" -> "text/html"
      ".svg" -> "image/svg+xml"
      ".json" -> "application/json"
      _ -> "application/octet-stream"
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :bad_json}
    end
  end

  defp fetch_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :"missing_#{key}"}
    end
  end

  defp fetch_library(params) do
    case Map.get(params, "library") do
      "echo" ->
        {:ok, :echo}

      value when is_binary(value) and value != "" ->
        try do
          {:ok, String.to_existing_atom(value)}
        rescue
          ArgumentError -> {:error, :unknown_library}
        end

      _ ->
        {:ok, Xylon.default_backend()}
    end
  end

  defp fetch_backend_opts(params) do
    case Map.get(params, "backend_opts") do
      nil ->
        {:ok, []}

      map when is_map(map) ->
        Signaling.backend_opts_from_map(map)

      _ ->
        {:error, :bad_backend_opts}
    end
  end

  defp offer_opts(conn, tenant_id, session_id, ctx) do
    query_pid = Map.get(conn.query_params, "participant_id")

    case ctx do
      %Context{participant_id: id} when is_binary(id) and id != "" ->
        case Auth.bind_participant(id, query_pid) do
          :ok ->
            {:ok, [participant_id: id, control_capabilities: ctx.capabilities]}

          {:error, :forbidden} ->
            {:error, :forbidden}
        end

      _ ->
        case query_pid do
          id when is_binary(id) and id != "" ->
            {:ok, [participant_id: id]}

          _ ->
            case session_participant_count(tenant_id, session_id) do
              n when is_integer(n) and n > 0 ->
                {:error, :missing_participant_id}

              _ ->
                {:ok, []}
            end
        end
    end
  end

  defp ban_gate(tenant_id, session_id, offer_opts) do
    participant_id = Keyword.get(offer_opts, :participant_id, "p1")

    if ControlRouter.banned?(tenant_id, session_id, participant_id) do
      {:error, :forbidden}
    else
      :ok
    end
  end

  defp subscribe_http(conn, session_id, action) do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: session_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- decode_subscribe_json(body),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, session_id, ctx),
         :ok <- ban_gate(tenant_id, session_id, offer_opts),
         {:ok, publisher_id} <- fetch_publisher_id(payload),
         {:ok, mid_or_all} <- fetch_subscribe_mid(payload, action) do
      subscriber_id = Keyword.get(offer_opts, :participant_id, "p1")

      result =
        case {action, mid_or_all} do
          {:subscribe, :all} ->
            Signaling.subscribe_all(
              tenant_id,
              session_id,
              subscriber_id,
              publisher_id,
              http_subscribe_opts(payload)
            )

          {:subscribe, mid} ->
            Signaling.subscribe(
              tenant_id,
              session_id,
              subscriber_id,
              publisher_id,
              mid,
              http_subscribe_opts(payload)
            )

          {:unsubscribe, mid} ->
            Signaling.unsubscribe(tenant_id, session_id, subscriber_id, publisher_id, mid)
        end

      case result do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :not_supported} ->
          send_resp(conn, 400, "not supported")

        {:error, reason} ->
          send_resp(conn, 400, "subscribe failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :missing_mid} ->
        send_resp(conn, 400, "missing mid")

      {:error, :missing_publisher_id} ->
        send_resp(conn, 400, "missing publisher_id")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  defp switch_http(conn, session_id) do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: session_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- decode_subscribe_json(body),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, session_id, ctx),
         :ok <- ban_gate(tenant_id, session_id, offer_opts),
         {:ok, mid} <- fetch_mid(payload),
         {:ok, publisher_id} <- fetch_publisher_id(payload) do
      subscriber_id = Keyword.get(offer_opts, :participant_id, "p1")

      case Signaling.switch(tenant_id, session_id, subscriber_id, publisher_id, mid) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :not_supported} ->
          send_resp(conn, 400, "not supported")

        {:error, reason} ->
          send_resp(conn, 400, "switch failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :missing_mid} ->
        send_resp(conn, 400, "missing mid")

      {:error, :missing_publisher_id} ->
        send_resp(conn, 400, "missing publisher_id")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  defp set_substream_http(conn, session_id) do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: session_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- decode_subscribe_json(body),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, session_id, ctx),
         :ok <- ban_gate(tenant_id, session_id, offer_opts),
         {:ok, mid} <- fetch_mid(payload),
         {:ok, publisher_id} <- fetch_publisher_id(payload) do
      subscriber_id = Keyword.get(offer_opts, :participant_id, "p1")

      case Signaling.set_substream(
             tenant_id,
             session_id,
             subscriber_id,
             publisher_id,
             mid,
             http_subscribe_opts(payload)
           ) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :not_supported} ->
          send_resp(conn, 400, "not supported")

        {:error, reason} ->
          send_resp(conn, 400, "set_substream failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :missing_mid} ->
        send_resp(conn, 400, "missing mid")

      {:error, :missing_publisher_id} ->
        send_resp(conn, 400, "missing publisher_id")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  defp unpublish_http(conn, session_id) do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: session_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- decode_subscribe_json(body),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, session_id, ctx),
         :ok <- ban_gate(tenant_id, session_id, offer_opts),
         {:ok, mids} <- fetch_unpublish_mids(payload) do
      participant_id = Keyword.get(offer_opts, :participant_id, "p1")

      case Signaling.unpublish(tenant_id, session_id, participant_id, mids) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :not_supported} ->
          send_resp(conn, 400, "not supported")

        {:error, reason} ->
          send_resp(conn, 400, "unpublish failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :bad_mids} ->
        send_resp(conn, 400, "invalid mids")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  defp update_http(conn, session_id) do
    with {:ok, tenant_id, ctx, conn} <-
           ControlRouter.require_tenant(conn, session_id: session_id),
         {:ok, body, conn} <- read_body(conn),
         {:ok, payload} <- decode_subscribe_json(body),
         {:ok, offer_opts} <- offer_opts(conn, tenant_id, session_id, ctx),
         :ok <- ban_gate(tenant_id, session_id, offer_opts),
         {:ok, streams} <- fetch_streams(payload) do
      subscriber_id = Keyword.get(offer_opts, :participant_id, "p1")

      case Signaling.update_subscriptions(tenant_id, session_id, subscriber_id, streams) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "session not found")

        {:error, :not_supported} ->
          send_resp(conn, 400, "not supported")

        {:error, reason} ->
          send_resp(conn, 400, "update failed: #{inspect(reason)}")
      end
    else
      {:error, :unauthorized, conn} ->
        send_resp(conn, 401, auth_error_message())

      {:error, :forbidden, conn} ->
        send_resp(conn, 403, "forbidden")

      {:error, :forbidden} ->
        send_resp(conn, 403, "forbidden")

      {:error, :missing_participant_id} ->
        send_resp(conn, 400, "missing participant_id")

      {:error, :bad_json} ->
        send_resp(conn, 400, "invalid json")

      {:error, :bad_streams} ->
        send_resp(conn, 400, "invalid streams")

      {:error, reason} ->
        send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  defp decode_subscribe_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :bad_json}
    end
  end

  defp fetch_mid(%{"mid" => mid}) when is_binary(mid) and mid != "", do: {:ok, mid}
  defp fetch_mid(_), do: {:error, :missing_mid}

  # Subscribe may omit mid (= all published mids). Unsubscribe requires mid.
  defp fetch_subscribe_mid(%{"mid" => mid}, _) when is_binary(mid) and mid != "", do: {:ok, mid}
  defp fetch_subscribe_mid(_payload, :subscribe), do: {:ok, :all}
  defp fetch_subscribe_mid(_payload, :unsubscribe), do: {:error, :missing_mid}

  defp fetch_unpublish_mids(%{"mids" => mids}) when is_list(mids) do
    if Enum.all?(mids, &(is_binary(&1) and &1 != "")) do
      {:ok, mids}
    else
      {:error, :bad_mids}
    end
  end

  defp fetch_unpublish_mids(_), do: {:ok, :all}

  defp fetch_streams(%{"streams" => streams}) when is_list(streams) do
    case Enum.reduce_while(streams, [], fn entry, acc ->
           case normalize_stream_entry(entry) do
             {:ok, normalized} -> {:cont, [normalized | acc]}
             :error -> {:halt, :bad}
           end
         end) do
      :bad -> {:error, :bad_streams}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp fetch_streams(_), do: {:error, :bad_streams}

  defp normalize_stream_entry(%{"publisher_id" => pub, "mid" => mid})
       when is_binary(pub) and pub != "" and is_binary(mid) and mid != "" do
    {:ok, %{publisher_id: pub, mid: mid}}
  end

  defp normalize_stream_entry(%{"publisher_id" => pub})
       when is_binary(pub) and pub != "" do
    {:ok, %{publisher_id: pub}}
  end

  defp normalize_stream_entry(_), do: :error

  defp fetch_publisher_id(%{"publisher_id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp fetch_publisher_id(_), do: {:error, :missing_publisher_id}

  defp http_subscribe_opts(payload) when is_map(payload) do
    []
    |> maybe_put_sub_opt(:substream, Map.get(payload, "substream"))
    |> maybe_put_sub_opt(:rid, Map.get(payload, "rid"))
    |> maybe_put_sub_opt(:temporal, Map.get(payload, "temporal"))
    |> maybe_put_sub_opt(:spatial_layer, Map.get(payload, "spatial_layer"))
    |> maybe_put_sub_opt(:temporal_layer, Map.get(payload, "temporal_layer"))
  end

  defp maybe_put_sub_opt(opts, :substream, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :substream, n)

  defp maybe_put_sub_opt(opts, :rid, rid) when is_binary(rid) and rid != "",
    do: Keyword.put(opts, :rid, rid)

  defp maybe_put_sub_opt(opts, :temporal, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :temporal, n)

  defp maybe_put_sub_opt(opts, :spatial_layer, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :spatial_layer, n)

  defp maybe_put_sub_opt(opts, :temporal_layer, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :temporal_layer, n)

  defp maybe_put_sub_opt(opts, _, _), do: opts

  defp upgrade_control_ws(conn) do
    conn_id = "cws-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    conn
    |> WebSockAdapter.upgrade(
      Xylon.Signaling.WSHandler,
      [conn_id: conn_id, query: conn.query_params],
      timeout: 60_000
    )
    |> halt()
  end

  defp session_participant_count(tenant_id, session_id) do
    case Xylon.Session.whereis(tenant_id, session_id) do
      nil -> 0
      pid -> map_size(:sys.get_state(pid).participants)
    end
  end
end
