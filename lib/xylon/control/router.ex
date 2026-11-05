defmodule Xylon.Control.Router do
  @moduledoc """
  Plug handlers for Control REST routes (inject, moderate, presence, history,
  groups, routes, record, live session list, fleet summary/nodes/accepting).

  ## What problem this solves

  HTTP clients and curl scripts need stable REST entry points for server-side
  room operations. Router authenticates via `Auth`, delegates to Inject,
  Moderation, Presence, History, Groups, egress routes, recording, the
  tenant-scoped live session list, and fleet load snapshots, and maps errors
  to HTTP status codes.
  Mounted beside `Xylon.Signaling.HTTP` when `config :xylon, control: [enabled: true]`.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane HTTP API.
  """

  import Plug.Conn

  alias Xylon.Control.{Acl, Auth, Context, Fleet, Groups, Inject, Membership, Moderation}
  alias Xylon.Session

  @doc "Handles `POST /v1/tenants/:tid/sessions/:sid/data`."
  @spec inject(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def inject(conn, tenant_id, session_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "participant_id")
           ),
         {:ok, payload} <- fetch_payload(params),
         dest <- Map.get(params, "dest", "all"),
         label <- label_from(params),
         :ok <- Inject.publish(ctx, payload, dest, label: label) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "session not found")
      {:error, :empty_dest} -> send_resp(conn, 404, "empty dest")
      {:error, :rate_limited} -> send_resp(conn, 429, "rate limited")
      {:error, :not_supported} -> send_resp(conn, 501, "not supported")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, conn} -> send_resp(conn, 400, "invalid json")
      {:error, :missing_payload} -> send_resp(conn, 400, "missing payload")
      {:error, reason} -> send_resp(conn, 400, "bad request: #{inspect(reason)}")
    end
  end

  @doc """
  Handles `POST /v1/tenants/:tid/sessions/:sid/dest/resolve`.

  Resolves inject-style `dest` to Backend shapes (`"all"` or an id list) without
  publishing. Session auth required; muted/banned actors are forbidden. Group
  dests require `groups:send` when capabilities are set. Does not consume inject
  quota or require inject capability.
  """
  @spec resolve_dest(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def resolve_dest(conn, tenant_id, session_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "participant_id")
           ),
         :ok <- resolve_moderation_gate(ctx),
         dest <- Map.get(params, "dest", "all"),
         :ok <- groups_send_gate(ctx, dest),
         {:ok, resolved} <-
           Xylon.Control.Dest.resolve(
             ctx.tenant_id,
             ctx.session_id,
             dest,
             ctx.participant_id
           ) do
      body = %{ok: true, dest: encode_resolved_dest(resolved)}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :empty_dest} -> send_resp(conn, 404, "empty dest")
      {:error, :bad_dest} -> send_resp(conn, 400, "bad dest")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, _conn} -> send_resp(conn, 400, "invalid json")
    end
  end

  defp groups_send_gate(ctx, dest) do
    if Acl.group_dest?(dest) do
      if Acl.allow_groups_send_dest?(ctx, dest), do: :ok, else: {:error, :forbidden}
    else
      :ok
    end
  end

  defp resolve_moderation_gate(%Context{} = ctx) do
    if Code.ensure_loaded?(Xylon.Control.Moderation) and
         function_exported?(Xylon.Control.Moderation, :blocked_inject?, 3) and
         Xylon.Control.Moderation.blocked_inject?(
           ctx.tenant_id,
           ctx.session_id,
           ctx.participant_id
         ) do
      {:error, :forbidden}
    else
      :ok
    end
  end

  defp encode_resolved_dest(:all), do: "all"
  defp encode_resolved_dest(ids) when is_list(ids), do: ids

  @doc """
  Handles `POST /v1/tenants/:tid/sessions/:sid/moderate`.

  Actions: `mute` / `unmute` / `ban` / `unban` / `kick`. Kick force-leaves the
  target via `Session.leave_participant/2` (feeds `unpublished` via the leave
  path); optional `"ban": true` sets ban in the same request. Kick is not stored
  as a Moderation flag.
  """
  @spec moderate(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def moderate(conn, tenant_id, session_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "participant_id")
           ),
         :ok <- moderate_acl(ctx),
         {:ok, action} <- fetch_action(params),
         {:ok, target} <- fetch_target(params),
         :ok <- apply_moderate(tenant_id, session_id, target, action, params, ctx) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, conn} -> send_resp(conn, 400, "invalid json")
      {:error, :missing_action} -> send_resp(conn, 400, "missing action")
      {:error, :missing_participant_id} -> send_resp(conn, 400, "missing participant_id")
      {:error, :bad_mids} -> send_resp(conn, 400, "invalid mids")
    end
  end

  @doc "Handles `POST /v1/tenants/:tid/sessions/:sid/record/start`."
  @spec record_start(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def record_start(conn, tenant_id, session_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json_optional(body),
         {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         true <- Acl.allow_record?(ctx) || {:error, :forbidden},
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         {:ok, info} <- Session.start_recording(session, params) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(stringify_recording(info)))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "session not found")
      {:error, :conflict} -> send_resp(conn, 409, "recording already active")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, conn} -> send_resp(conn, 400, "invalid json")
      {:error, _} -> send_resp(conn, 400, "bad request")
    end
  end

  @doc "Handles `POST /v1/tenants/:tid/sessions/:sid/record/stop`."
  @spec record_stop(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def record_stop(conn, tenant_id, session_id) do
    with {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         true <- Acl.allow_record?(ctx) || {:error, :forbidden},
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         {:ok, info} <- Session.stop_recording(session) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(stringify_recording(info)))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, _} -> send_resp(conn, 400, "bad request")
    end
  end

  @doc "Handles `GET /v1/tenants/:tid/sessions/:sid/record`."
  @spec record_get(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def record_get(conn, tenant_id, session_id) do
    with {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         true <- Acl.allow_record?(ctx) || {:error, :forbidden},
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         {:ok, info} <- Session.get_recording(session) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(stringify_recording(info)))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, _} -> send_resp(conn, 400, "bad request")
    end
  end

  @doc """
  Handles `GET /v1/tenants/:tid/sessions`.

  Lists local live Sessions for the tenant (Registry), with `participant_count`
  from Membership. Each row includes this edge's `node` and `region`.
  """
  @spec sessions_list(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def sessions_list(conn, tenant_id) do
    with {:ok, ctx} <- Auth.authenticate(conn, tenant_id: tenant_id),
         true <- Acl.allow_sessions?(ctx) || {:error, :forbidden} do
      node = Atom.to_string(Node.self())
      region = Xylon.Cluster.local_region()

      sessions =
        Registry.select(Xylon.Registry, [
          {{{tenant_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
        ])
        |> Enum.map(fn {session_id, _pid} ->
          %{
            "session_id" => session_id,
            "participant_count" => map_size(Membership.list(tenant_id, session_id)),
            "node" => node,
            "region" => region
          }
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"sessions" => sessions}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc """
  Handles `GET /v1/tenants/:tid/fleet/summary`.

  Aggregates node snapshots (local + `:erpc` peers) into region/node/load totals.
  """
  @spec fleet_summary(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def fleet_summary(conn, tenant_id) do
    with {:ok, ctx} <- Auth.authenticate(conn, tenant_id: tenant_id),
         true <- Acl.allow_fleet?(ctx) || {:error, :forbidden} do
      nodes = Fleet.collect_nodes(tenant_id)
      summary = Fleet.summary_from_nodes(nodes)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"summary" => summary}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc """
  Handles `GET /v1/tenants/:tid/fleet/nodes`.

  Returns per-node load rows (counts and ids only).
  """
  @spec fleet_nodes(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def fleet_nodes(conn, tenant_id) do
    with {:ok, ctx} <- Auth.authenticate(conn, tenant_id: tenant_id),
         true <- Acl.allow_fleet?(ctx) || {:error, :forbidden} do
      nodes = Fleet.collect_nodes(tenant_id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"nodes" => nodes}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc """
  Handles `POST /v1/tenants/:tid/fleet/accepting`.

  Body: `{"node":"a@host","accepting":false}`. Sets drain/undrain on that
  in-region node (local or `:erpc`). Capability `"fleet"`.
  """
  @spec fleet_accepting(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  def fleet_accepting(conn, tenant_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <- Auth.authenticate(conn, tenant_id: tenant_id),
         true <- Acl.allow_fleet?(ctx) || {:error, :forbidden},
         {:ok, node_str} <- fetch_accepting_node(params),
         {:ok, flag} <- fetch_accepting_flag(params),
         {:ok, node} <- resolve_fleet_node(node_str),
         :ok <- Xylon.Cluster.Accepting.set_on(node, flag) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"node" => node_str, "accepting" => flag}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :missing_node} -> send_resp(conn, 400, "missing node")
      {:error, :missing_accepting} -> send_resp(conn, 400, "missing accepting")
      {:error, :unknown_node} -> send_resp(conn, 404, "unknown node")
      {:error, reason} -> send_resp(conn, 502, "accepting failed: #{inspect(reason)}")
    end
  end

  @doc "True when participant is banned from join/offer."
  @spec banned?(term(), term(), term()) :: boolean()
  def banned?(tenant_id, session_id, participant_id) do
    Code.ensure_loaded?(Moderation) and
      Moderation.blocked_join?(tenant_id, session_id, participant_id)
  end

  defp moderate_acl(%Context{capabilities: caps}) do
    cond do
      caps in [nil, [], %{}] -> :ok
      is_list(caps) and "moderate" in caps -> :ok
      is_map(caps) and (Map.get(caps, "moderate") == true or Map.get(caps, :moderate) == true) ->
        :ok
      true -> {:error, :forbidden}
    end
  end

  defp fetch_action(%{"action" => "mute"}), do: {:ok, :mute}
  defp fetch_action(%{"action" => "unmute"}), do: {:ok, :unmute}
  defp fetch_action(%{"action" => "ban"}), do: {:ok, :ban}
  defp fetch_action(%{"action" => "unban"}), do: {:ok, :unban}
  defp fetch_action(%{"action" => "kick"}), do: {:ok, :kick}

  defp fetch_action(_), do: {:error, :missing_action}

  defp fetch_target(%{"participant_id" => id}) when is_binary(id) and id != "" do
    {:ok, id}
  end

  defp fetch_target(_), do: {:error, :missing_participant_id}

  defp fetch_accepting_node(%{"node" => node}) when is_binary(node) and node != "" do
    {:ok, node}
  end

  defp fetch_accepting_node(_), do: {:error, :missing_node}

  defp fetch_accepting_flag(%{"accepting" => flag}) when is_boolean(flag), do: {:ok, flag}
  defp fetch_accepting_flag(_), do: {:error, :missing_accepting}

  defp resolve_fleet_node(node_str) when is_binary(node_str) do
    allowed =
      Xylon.Cluster.nodes_in_region()
      |> Map.new(fn n -> {Atom.to_string(n), n} end)

    case Map.fetch(allowed, node_str) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :unknown_node}
    end
  end

  defp apply_moderate(tenant_id, session_id, target, :kick, params, ctx) do
    mod_opts = [actor: ctx.participant_id, reason: Map.get(params, "reason")]

    with :ok <- maybe_notice(ctx, params, target, :kick),
         :ok <- maybe_ban_on_kick(tenant_id, session_id, target, params, mod_opts),
         :ok <- audit_kick(tenant_id, session_id, target, mod_opts),
         :ok <- force_leave(tenant_id, session_id, target) do
      :ok
    end
  end

  defp apply_moderate(tenant_id, session_id, target, action, params, ctx)
       when action in [:mute, :unmute, :ban, :unban] do
    with :ok <-
           Moderation.set(tenant_id, session_id, target, action,
             actor: ctx.participant_id,
             reason: Map.get(params, "reason")
           ),
         :ok <- maybe_av_moderate(tenant_id, session_id, target, action, params),
         :ok <- maybe_notice(ctx, params, target, action) do
      :ok
    end
  end

  defp maybe_ban_on_kick(tenant_id, session_id, target, %{"ban" => true}, opts) do
    Moderation.set(tenant_id, session_id, target, :ban, opts)
  end

  defp maybe_ban_on_kick(_, _, _, _, _), do: :ok

  defp audit_kick(tenant_id, session_id, target, opts) do
    if Code.ensure_loaded?(Xylon.Control.Audit) do
      Xylon.Control.Audit.append(tenant_id, session_id, %{
        action: :kick,
        target: target,
        actor: Keyword.get(opts, :actor),
        reason: Keyword.get(opts, :reason)
      })
    end

    :ok
  end

  defp force_leave(tenant_id, session_id, target) do
    case Session.whereis(tenant_id, session_id) do
      nil ->
        :ok

      pid ->
        _ = Session.leave_participant(pid, target)
        :ok
    end
  end

  defp maybe_notice(ctx, %{"notice" => true} = params, target, action) do
    Inject.notice(ctx, target, action, reason: Map.get(params, "reason"))
  end

  defp maybe_notice(_, _, _, _), do: :ok

  defp maybe_av_moderate(tenant_id, session_id, target, action, params)
       when action in [:mute, :unmute] do
    with {:ok, mids} <- fetch_mids(params) do
      case Session.whereis(tenant_id, session_id) do
        nil ->
          :ok

        pid ->
          case Session.moderate_av(pid, target, action, mids) do
            :ok -> :ok
            {:error, _} -> :ok
          end
      end
    end
  end

  defp maybe_av_moderate(_, _, _, _, _), do: :ok

  defp fetch_mids(%{"mids" => []}), do: {:error, :bad_mids}

  defp fetch_mids(%{"mids" => mids}) when is_list(mids) do
    if Enum.all?(mids, &(is_binary(&1) and &1 != "")) do
      {:ok, mids}
    else
      {:error, :bad_mids}
    end
  end

  defp fetch_mids(_), do: {:ok, nil}

  @doc "Handles `GET /v1/tenants/:tid/sessions/:sid/presence`."
  @spec presence(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def presence(conn, tenant_id, session_id) do
    with {:ok, _ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id) do
      members = Xylon.Control.Presence.list(tenant_id, session_id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{participants: members}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc "Handles `GET /v1/tenants/:tid/sessions/:sid/history`."
  @spec history(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def history(conn, tenant_id, session_id) do
    with {:ok, _ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id) do
      label = Map.get(conn.query_params, "label", "chat")
      messages = Xylon.Control.History.list(tenant_id, session_id, label)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{messages: messages}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc "Handles `GET /v1/tenants/:tid/sessions/:sid/groups`."
  @spec groups_list(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def groups_list(conn, tenant_id, session_id) do
    with {:ok, _ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{groups: Groups.list(tenant_id, session_id)}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
    end
  end

  @doc "Handles `POST /v1/tenants/:tid/sessions/:sid/groups`."
  @spec groups_create(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def groups_create(conn, tenant_id, session_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "participant_id")
           ),
         {:ok, gid} <- fetch_group_id(params),
         :ok <- groups_mutate_acl(ctx, gid),
         :ok <- Groups.create(tenant_id, session_id, gid) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true, group_id: gid}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :already_exists} -> send_resp(conn, 409, "already exists")
      {:error, :bad_group_id} -> send_resp(conn, 400, "missing group_id")
      {:error, :missing_group_id} -> send_resp(conn, 400, "missing group_id")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, _conn} -> send_resp(conn, 400, "invalid json")
    end
  end

  @doc "Handles `DELETE /v1/tenants/:tid/sessions/:sid/groups/:gid`."
  @spec groups_delete(Plug.Conn.t(), binary(), binary(), binary()) :: Plug.Conn.t()
  def groups_delete(conn, tenant_id, session_id, group_id) do
    with {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         :ok <- groups_mutate_acl(ctx, group_id),
         :ok <- Groups.delete(tenant_id, session_id, group_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, :bad_group_id} -> send_resp(conn, 400, "bad group_id")
    end
  end

  @doc "Handles `POST /v1/tenants/:tid/sessions/:sid/groups/:gid/members`."
  @spec groups_add_member(Plug.Conn.t(), binary(), binary(), binary()) :: Plug.Conn.t()
  def groups_add_member(conn, tenant_id, session_id, group_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "actor_id")
           ),
         :ok <- groups_mutate_acl(ctx, group_id),
         {:ok, member_id} <- fetch_member_id(params),
         :ok <- Groups.add_member(tenant_id, session_id, group_id, member_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, :not_in_session} -> send_resp(conn, 404, "participant not in session")
      {:error, :bad_group_id} -> send_resp(conn, 400, "bad group_id")
      {:error, :missing_participant_id} -> send_resp(conn, 400, "missing participant_id")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, _conn} -> send_resp(conn, 400, "invalid json")
    end
  end

  @doc "Handles `DELETE /v1/tenants/:tid/sessions/:sid/groups/:gid/members/:pid`."
  @spec groups_remove_member(Plug.Conn.t(), binary(), binary(), binary(), binary()) ::
          Plug.Conn.t()
  def groups_remove_member(conn, tenant_id, session_id, group_id, member_id) do
    with {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         :ok <- groups_mutate_acl(ctx, group_id),
         :ok <- Groups.remove_member(tenant_id, session_id, group_id, member_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "not found")
      {:error, :bad_group_id} -> send_resp(conn, 400, "bad group_id")
    end
  end

  defp groups_mutate_acl(ctx, group_id) do
    if Acl.allow_groups_mutate?(ctx, group_id), do: :ok, else: {:error, :forbidden}
  end

  defp fetch_group_id(%{"group_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_group_id(_), do: {:error, :missing_group_id}

  defp fetch_member_id(%{"participant_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp fetch_member_id(_), do: {:error, :missing_participant_id}

  @doc "Handles `GET /v1/tenants/:tid/sessions/:sid/routes`."
  @spec routes_list(Plug.Conn.t(), binary(), binary()) :: Plug.Conn.t()
  def routes_list(conn, tenant_id, session_id) do
    with {:ok, _ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         routes when is_list(routes) <- list_routes(session) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{routes: routes}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "session not found")
      {:error, :not_supported} -> send_resp(conn, 501, "not supported")
    end
  end

  @doc "Handles `PUT /v1/tenants/:tid/sessions/:sid/routes/:sender_id`."
  @spec routes_put(Plug.Conn.t(), binary(), binary(), binary()) :: Plug.Conn.t()
  def routes_put(conn, tenant_id, session_id, sender_id) do
    with {:ok, body, conn} <- read_body_safe(conn),
         {:ok, params} <- decode_json(body),
         {:ok, ctx} <-
           Auth.authenticate(conn,
             tenant_id: tenant_id,
             session_id: session_id,
             participant_id: Map.get(params, "participant_id")
           ),
         :ok <- routes_mutate_acl(ctx),
         {:ok, dest} <- fetch_route_dest(params),
         opts <- route_label_opts(params),
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         :ok <- set_route(session, sender_id, dest, opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "session not found")
      {:error, :unknown_sender} -> send_resp(conn, 404, "sender not found")
      {:error, :bad_dest} -> send_resp(conn, 400, "bad dest")
      {:error, :missing_dest} -> send_resp(conn, 400, "missing dest")
      {:error, :not_supported} -> send_resp(conn, 501, "not supported")
      {:error, :bad_json} -> send_resp(conn, 400, "invalid json")
      {:error, :bad_json, _conn} -> send_resp(conn, 400, "invalid json")
    end
  end

  @doc """
  Handles `DELETE /v1/tenants/:tid/sessions/:sid/routes/:sender_id`.

  Without `?label=`, clears all labels for the sender. With `?label=`, clears that row.
  """
  @spec routes_delete(Plug.Conn.t(), binary(), binary(), binary()) :: Plug.Conn.t()
  def routes_delete(conn, tenant_id, session_id, sender_id) do
    with {:ok, ctx} <-
           Auth.authenticate(conn, tenant_id: tenant_id, session_id: session_id),
         :ok <- routes_mutate_acl(ctx),
         opts <- route_label_opts_from_query(conn),
         {:ok, session} <- fetch_live_session(tenant_id, session_id),
         :ok <- clear_route(session, sender_id, opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ok: true}))
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :forbidden} -> send_resp(conn, 403, "forbidden")
      {:error, :not_found} -> send_resp(conn, 404, "session not found")
      {:error, :not_supported} -> send_resp(conn, 501, "not supported")
    end
  end

  defp routes_mutate_acl(ctx) do
    if Acl.allow_routes_mutate?(ctx), do: :ok, else: {:error, :forbidden}
  end

  defp fetch_live_session(tenant_id, session_id) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp fetch_route_dest(%{"dest" => "all"}), do: {:ok, :all}
  defp fetch_route_dest(%{"dest" => "except"}), do: {:ok, :except_sender}
  defp fetch_route_dest(%{"dest" => "except_sender"}), do: {:ok, :except_sender}

  defp fetch_route_dest(%{"dest" => ids}) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) or ids == [] do
      {:ok, ids}
    else
      {:error, :bad_dest}
    end
  end

  defp fetch_route_dest(%{"dest" => _}), do: {:error, :bad_dest}
  defp fetch_route_dest(_), do: {:error, :missing_dest}

  defp route_label_opts(%{"label" => label}) when is_binary(label) and label != "" do
    [label: label]
  end

  defp route_label_opts(_), do: []

  defp route_label_opts_from_query(conn) do
    case Map.get(conn.query_params, "label") do
      label when is_binary(label) and label != "" -> [label: label]
      _ -> []
    end
  end

  defp set_route(session, sender_id, dest, opts) do
    dc = Module.concat([Xylon, Datachannel])

    cond do
      Code.ensure_loaded?(dc) and function_exported?(dc, :set_route, 4) ->
        apply(dc, :set_route, [session, sender_id, dest, opts])

      true ->
        Session.set_egress_route(session, sender_id, dest, opts)
    end
  end

  defp clear_route(session, sender_id, opts) do
    dc = Module.concat([Xylon, Datachannel])

    cond do
      Code.ensure_loaded?(dc) and function_exported?(dc, :clear_route, 3) ->
        apply(dc, :clear_route, [session, sender_id, opts])

      true ->
        Session.clear_egress_route(session, sender_id, opts)
    end
  end

  defp list_routes(session) do
    dc = Module.concat([Xylon, Datachannel])

    cond do
      Code.ensure_loaded?(dc) and function_exported?(dc, :list_routes, 1) ->
        apply(dc, :list_routes, [session])

      true ->
        {:error, :not_supported}
    end
  end

  @doc """
  Resolves tenant for create/offer when control auth is `:hmac`.

  Lab mode keeps `x-tenant-id`. HMAC ignores bare `x-tenant-id` and uses the bearer.
  """
  @spec require_tenant(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Context.t() | nil, Plug.Conn.t()}
          | {:error, :unauthorized | :forbidden, Plug.Conn.t()}
  def require_tenant(conn, opts \\ []) do
    if Auth.enabled?() and Auth.auth_mode() in [:hmac, :jwt] do
      case Auth.authenticate(conn, opts) do
        {:ok, %Context{} = ctx} ->
          {:ok, ctx.tenant_id, ctx, conn}

        {:error, :forbidden} ->
          {:error, :forbidden, conn}

        {:error, _} ->
          {:error, :unauthorized, conn}
      end
    else
      case get_req_header(conn, "x-tenant-id") do
        [tenant_id | _] when tenant_id != "" -> {:ok, tenant_id, nil, conn}
        _ -> {:error, :unauthorized, conn}
      end
    end
  end

  defp label_from(params) do
    case Map.get(params, "label") do
      label when is_binary(label) and label != "" -> label
      _ ->
        case Map.get(params, "topic") do
          topic when is_binary(topic) and topic != "" -> Inject.default_label(topic)
          _ -> nil
        end
    end
  end

  defp fetch_payload(params) do
    case Map.get(params, "payload") do
      payload when is_binary(payload) -> {:ok, payload}
      payload when is_map(payload) or is_list(payload) -> {:ok, Jason.encode!(payload)}
      _ -> {:error, :missing_payload}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :bad_json}
    end
  end

  defp decode_json_optional(""), do: {:ok, %{}}
  defp decode_json_optional(nil), do: {:ok, %{}}

  defp decode_json_optional(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:ok, %{}}
      trimmed -> decode_json(trimmed)
    end
  end

  defp stringify_recording(info) when is_map(info) do
    info
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_recording_value(v)}
      {k, v} -> {k, stringify_recording_value(v)}
    end)
    |> Map.new()
  end

  defp stringify_recording_value(nil), do: nil
  defp stringify_recording_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_recording_value(v), do: v

  defp read_body_safe(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, conn} -> {:error, :bad_json, conn}
      {:error, _reason} -> {:error, :bad_json}
    end
  end
end
