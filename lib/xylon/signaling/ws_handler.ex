defmodule Xylon.Signaling.WSHandler do
  @moduledoc """
  Browser JSEP control plane over WebSocket.

  ## What problem this solves

  Interactive lab clients need a single long-lived connection for join, SDP
  offer/answer, Trickle ICE, subscribe/switch, and optional presence/feeds
  snapshots. This WebSock handler decodes JSON frames, authenticates via
  `Xylon.Control.Auth`, and delegates media operations to `Xylon.Signaling`.
  Under `:hmac` / `:jwt`, join keeps the token `participant_id` (optional
  frame/query id must match; never overrides).

  When `Xylon.Ice.full?/0`, offers start full-ICE peers and this handler pushes
  server `ice` / `ice_complete` frames from peer gather events. Otherwise the
  server stays ICE-lite (host candidates in the answer SDP only).

  **Internal:** upgraded from `GET /v1/ws` in `Xylon.Signaling.HTTP` when
  control is enabled. Frame types: `join`, `offer`, `ice`, `subscribe`,
  `  unsubscribe`, `switch`, `set_substream`, `unpublish`, `update`, plus server
  pushes for `answer`, presence, feeds, and groups.

  ## RFCs and related specs

  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) -- JSEP signaling model
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via [XSDP](https://github.com/Lazarus404/xsdp))
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE trickle (`ice` / `ice_complete` frames)
  """
  @behaviour WebSock

  alias Xylon.Control.{Auth, Context, Feeds, Groups, Presence, Quota, Router}
  alias Xylon.Signaling

  @impl true
  def init(opts) do
    {:ok,
     %{
       conn_id: Keyword.get(opts, :conn_id),
       query: Keyword.get(opts, :query, %{}),
       ctx: nil,
       tenant_id: nil,
       session_id: nil,
       participant_id: nil
     }}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => "join"} = msg} ->
        handle_join(msg, state)

      {:ok, %{"type" => "offer"} = msg} ->
        handle_offer(msg, state)

      {:ok, %{"type" => "ice"} = msg} ->
        handle_ice(msg, state)

      {:ok, %{"type" => "subscribe"} = msg} ->
        handle_subscribe(msg, state, :subscribe)

      {:ok, %{"type" => "unsubscribe"} = msg} ->
        handle_subscribe(msg, state, :unsubscribe)

      {:ok, %{"type" => "switch"} = msg} ->
        handle_switch(msg, state)

      {:ok, %{"type" => "set_substream"} = msg} ->
        handle_set_substream(msg, state)

      {:ok, %{"type" => "unpublish"} = msg} ->
        handle_unpublish(msg, state)

      {:ok, %{"type" => "update"} = msg} ->
        handle_update(msg, state)

      {:ok, _} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_type"})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_json"})}, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  def handle_info({:xylon_control_ice, %{type: :ice} = payload}, state) do
    frame = %{
      type: "ice",
      candidate: Map.get(payload, :candidate),
      sdpMid: Map.get(payload, :sdpMid),
      sdpMLineIndex: Map.get(payload, :sdpMLineIndex, 0)
    }

    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_ice, %{type: :ice_complete}}, state) do
    {:push, {:text, Jason.encode!(%{type: "ice_complete"})}, state}
  end

  def handle_info({:xylon_control_publish_layers, %{mid: mid, layers: layers}}, state)
      when is_binary(mid) and is_list(layers) do
    frame = %{type: "publish_layers", mid: mid, layers: layers}
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_presence, %{type: :diff} = payload}, state) do
    frame = presence_diff_frame(payload)
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_presence, %{type: type} = payload}, state)
      when type in [:talking, :stopped_talking] do
    frame = talking_frame(payload)
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_presence, %{type: :feeds_diff} = payload}, state) do
    frame = feeds_diff_frame(payload)
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_presence, %{type: :groups_diff} = payload}, state) do
    frame = groups_diff_frame(payload)
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info({:xylon_control_presence, %{type: :migrate_required} = payload}, state) do
    frame = migrate_required_frame(payload)
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    maybe_unsubscribe(state)
    :ok
  end

  defp handle_join(msg, state) do
    with {:ok, ctx} <- auth_from_msg(msg, state),
         tenant_id <- ctx.tenant_id,
         session_id <- ctx.session_id,
         false <- Router.banned?(tenant_id, session_id, ctx.participant_id),
         :ok <- Quota.gate_join(tenant_id, session_id),
         {:ok, _pid} <- ensure_session(msg, ctx) do
      state = %{
        state
        | ctx: ctx,
          tenant_id: tenant_id,
          session_id: session_id,
          participant_id: ctx.participant_id
      }

      frames =
        [{:text, Jason.encode!(%{type: "joined", session_id: session_id})}] ++
          presence_join_frames(tenant_id, session_id, ctx.participant_id)

      {:push, frames, state}
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
    end
  end

  defp presence_join_frames(tenant_id, session_id, participant_id) do
    if Process.whereis(Presence) do
      _ = Presence.subscribe(tenant_id, session_id, participant_id, self())

      frames = [
        {:text,
         Jason.encode!(%{
           type: "presence.snapshot",
           participants: Presence.snapshot_payload(tenant_id, session_id)
         })}
      ]

      frames =
        if Code.ensure_loaded?(Feeds) do
          frames ++
            [
              {:text,
               Jason.encode!(%{
                 type: "feeds.snapshot",
                 publishers: Feeds.snapshot_payload(tenant_id, session_id)
               })}
            ]
        else
          frames
        end

      if Code.ensure_loaded?(Groups) do
        frames ++
          [
            {:text,
             Jason.encode!(%{
               type: "groups.snapshot",
               groups: Groups.snapshot_payload(tenant_id, session_id)
             })}
          ]
      else
        frames
      end
    else
      []
    end
  end

  defp presence_diff_frame(payload) do
    frame = %{
      type: "presence.diff",
      action: Atom.to_string(Map.fetch!(payload, :action)),
      participant_id: Map.fetch!(payload, :participant_id)
    }

    frame =
      case Map.get(payload, :role) do
        nil -> frame
        role when is_atom(role) -> Map.put(frame, :role, Atom.to_string(role))
        role -> Map.put(frame, :role, role)
      end

    frame =
      case Map.get(payload, :joined_at) do
        nil -> frame
        ts -> Map.put(frame, :joined_at, ts)
      end

    case Map.get(payload, :meta) do
      meta when is_map(meta) and map_size(meta) > 0 -> Map.put(frame, :meta, meta)
      _ -> frame
    end
  end

  defp talking_frame(payload) do
    type =
      case Map.fetch!(payload, :type) do
        :talking -> "talking"
        :stopped_talking -> "stopped-talking"
      end

    frame = %{
      type: type,
      participant_id: Map.fetch!(payload, :participant_id)
    }

    case Map.get(payload, :audio_level_dbov_avg) do
      nil -> frame
      avg -> Map.put(frame, :audio_level_dbov_avg, avg)
    end
  end

  defp feeds_diff_frame(payload) do
    %{
      type: "feeds.diff",
      action: Atom.to_string(Map.fetch!(payload, :action)),
      participant_id: Map.fetch!(payload, :participant_id),
      streams: Map.get(payload, :streams) || []
    }
  end

  defp groups_diff_frame(payload) do
    frame = %{
      type: "groups.diff",
      action: Atom.to_string(Map.fetch!(payload, :action)),
      group_id: Map.fetch!(payload, :group_id)
    }

    case Map.get(payload, :participant_id) do
      nil -> frame
      pid -> Map.put(frame, :participant_id, pid)
    end
  end

  defp migrate_required_frame(payload) do
    target = Map.get(payload, :target) || %{}
    {tenant, session} = Map.get(payload, :session_key) || {nil, nil}

    %{
      type: "migrate.required",
      reason: reason_string(Map.get(payload, :reason, :edge_down)),
      tenant_id: tenant,
      session_id: session,
      target: %{
        edge_url: Map.get(target, :edge_url),
        node: Map.get(target, :node),
        region_id: Map.get(target, :region_id),
        role: role_string(Map.get(target, :role))
      }
    }
  end

  defp role_string(role) when is_atom(role), do: Atom.to_string(role)
  defp role_string(role) when is_binary(role), do: role
  defp role_string(_), do: nil

  defp maybe_unsubscribe(%{tenant_id: tid, session_id: sid, participant_id: pid})
       when not is_nil(tid) and not is_nil(sid) and not is_nil(pid) do
    if Process.whereis(Presence) do
      _ = Presence.unsubscribe(tid, sid, pid)
    end

    :ok
  end

  defp maybe_unsubscribe(_), do: :ok

  defp handle_offer(msg, state) do
    with %Context{} = ctx <- state.ctx || auth_ctx!(msg, state),
         sdp when is_binary(sdp) and sdp != "" <- Map.get(msg, "sdp"),
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, answer} <-
           Signaling.apply_remote_offer(ctx.tenant_id, ctx.session_id, sdp,
             participant_id: ctx.participant_id,
             ice_mode: control_ice_mode(),
             control_capabilities: ctx.capabilities
           ) do
      case Xylon.Session.whereis(ctx.tenant_id, ctx.session_id) do
        session when is_pid(session) ->
          _ = Xylon.Session.bind_signaling(session, ctx.participant_id, self())

        _ ->
          :ok
      end

      {:push, {:text, Jason.encode!(%{type: "answer", sdp: answer})},
       %{state | ctx: ctx, tenant_id: ctx.tenant_id, session_id: ctx.session_id}}
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      {:error, :forbidden} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: inspect(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_offer"})}, state}
    end
  end

  defp control_ice_mode do
    if Xylon.Ice.full?(), do: :full, else: :lite
  end

  defp handle_ice(msg, state) do
    with %Context{} = ctx <- state.ctx || auth_ctx!(msg, state),
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, info} <- normalize_ice(msg),
         :ok <-
           Signaling.add_remote_candidate(
             ctx.tenant_id,
             ctx.session_id,
             ctx.participant_id,
             info
           ) do
      {:push, {:text, Jason.encode!(%{type: "ice_ok"})},
       %{state | ctx: ctx, tenant_id: ctx.tenant_id, session_id: ctx.session_id}}
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "unauthorized"})}, state}
    end
  end

  defp handle_subscribe(msg, state, action) do
    with %Context{} = ctx <- state.ctx,
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, publisher_id} <- ws_publisher_id(msg),
         {:ok, mid_or_all} <- ws_subscribe_mid(msg, action) do
      result =
        case {action, mid_or_all} do
          {:subscribe, :all} ->
            Signaling.subscribe_all(
              ctx.tenant_id,
              ctx.session_id,
              ctx.participant_id,
              publisher_id,
              ws_subscribe_opts(msg)
            )

          {:subscribe, mid} ->
            Signaling.subscribe(
              ctx.tenant_id,
              ctx.session_id,
              ctx.participant_id,
              publisher_id,
              mid,
              ws_subscribe_opts(msg)
            )

          {:unsubscribe, mid} ->
            Signaling.unsubscribe(
              ctx.tenant_id,
              ctx.session_id,
              ctx.participant_id,
              publisher_id,
              mid
            )
        end

      case result do
        :ok ->
          type = if action == :subscribe, do: "subscribed", else: "unsubscribed"
          {:push, {:text, Jason.encode!(%{type: type})}, state}

        {:error, reason} ->
          {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
      end
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      nil ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "not_joined"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_subscribe"})}, state}
    end
  end

  defp handle_switch(msg, state) do
    with %Context{} = ctx <- state.ctx,
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, mid} <- ws_mid(msg),
         {:ok, publisher_id} <- ws_publisher_id(msg) do
      case Signaling.switch(
             ctx.tenant_id,
             ctx.session_id,
             ctx.participant_id,
             publisher_id,
             mid
           ) do
        :ok ->
          {:push, {:text, Jason.encode!(%{type: "switched"})}, state}

        {:error, reason} ->
          {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
      end
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      nil ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "not_joined"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_switch"})}, state}
    end
  end

  defp handle_set_substream(msg, state) do
    with %Context{} = ctx <- state.ctx,
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, mid} <- ws_mid(msg),
         {:ok, publisher_id} <- ws_publisher_id(msg) do
      case Signaling.set_substream(
             ctx.tenant_id,
             ctx.session_id,
             ctx.participant_id,
             publisher_id,
             mid,
             ws_subscribe_opts(msg)
           ) do
        :ok ->
          {:push, {:text, Jason.encode!(%{type: "substream_set"})}, state}

        {:error, reason} ->
          {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
      end
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      nil ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "not_joined"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_set_substream"})}, state}
    end
  end

  defp handle_unpublish(msg, state) do
    with %Context{} = ctx <- state.ctx,
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, mids} <- ws_unpublish_mids(msg) do
      case Signaling.unpublish(
             ctx.tenant_id,
             ctx.session_id,
             ctx.participant_id,
             mids
           ) do
        :ok ->
          {:push, {:text, Jason.encode!(%{type: "unpublished"})}, state}

        {:error, reason} ->
          {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
      end
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      nil ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "not_joined"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_unpublish"})}, state}
    end
  end

  defp handle_update(msg, state) do
    with %Context{} = ctx <- state.ctx,
         false <- Router.banned?(ctx.tenant_id, ctx.session_id, ctx.participant_id),
         {:ok, streams} <- ws_streams(msg) do
      case Signaling.update_subscriptions(
             ctx.tenant_id,
             ctx.session_id,
             ctx.participant_id,
             streams
           ) do
        :ok ->
          {:push, {:text, Jason.encode!(%{type: "updated"})}, state}

        {:error, reason} ->
          {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}
      end
    else
      true ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "forbidden"})}, state}

      nil ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "not_joined"})}, state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: reason_string(reason)})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", reason: "bad_update"})}, state}
    end
  end

  defp ws_mid(%{"mid" => mid}) when is_binary(mid) and mid != "", do: {:ok, mid}
  defp ws_mid(_), do: {:error, :missing_mid}

  defp ws_subscribe_mid(%{"mid" => mid}, _) when is_binary(mid) and mid != "", do: {:ok, mid}
  defp ws_subscribe_mid(_msg, :subscribe), do: {:ok, :all}
  defp ws_subscribe_mid(_msg, :unsubscribe), do: {:error, :missing_mid}

  defp ws_unpublish_mids(%{"mids" => mids}) when is_list(mids) do
    if Enum.all?(mids, &(is_binary(&1) and &1 != "")) do
      {:ok, mids}
    else
      {:error, :bad_mids}
    end
  end

  defp ws_unpublish_mids(_), do: {:ok, :all}

  defp ws_streams(%{"streams" => streams}) when is_list(streams) do
    case Enum.reduce_while(streams, [], fn entry, acc ->
           case ws_stream_entry(entry) do
             {:ok, normalized} -> {:cont, [normalized | acc]}
             :error -> {:halt, :bad}
           end
         end) do
      :bad -> {:error, :bad_streams}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp ws_streams(_), do: {:error, :bad_streams}

  defp ws_stream_entry(%{"publisher_id" => pub, "mid" => mid})
       when is_binary(pub) and pub != "" and is_binary(mid) and mid != "" do
    {:ok, %{publisher_id: pub, mid: mid}}
  end

  defp ws_stream_entry(%{"publisher_id" => pub}) when is_binary(pub) and pub != "" do
    {:ok, %{publisher_id: pub}}
  end

  defp ws_stream_entry(_), do: :error
  defp ws_publisher_id(%{"publisher_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp ws_publisher_id(_), do: {:error, :missing_publisher_id}

  defp ws_subscribe_opts(msg) when is_map(msg) do
    []
    |> maybe_put_opt(:substream, Map.get(msg, "substream"))
    |> maybe_put_opt(:rid, Map.get(msg, "rid"))
    |> maybe_put_opt(:temporal, Map.get(msg, "temporal"))
    |> maybe_put_opt(:spatial_layer, Map.get(msg, "spatial_layer"))
    |> maybe_put_opt(:temporal_layer, Map.get(msg, "temporal_layer"))
  end

  defp maybe_put_opt(opts, :substream, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :substream, n)

  defp maybe_put_opt(opts, :rid, rid) when is_binary(rid) and rid != "",
    do: Keyword.put(opts, :rid, rid)

  defp maybe_put_opt(opts, :temporal, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :temporal, n)

  defp maybe_put_opt(opts, :spatial_layer, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :spatial_layer, n)

  defp maybe_put_opt(opts, :temporal_layer, n) when is_integer(n) and n >= 0,
    do: Keyword.put(opts, :temporal_layer, n)

  defp maybe_put_opt(opts, _, _), do: opts

  defp normalize_ice(msg) when is_map(msg) do
    mid = Map.get(msg, "sdpMid") || Map.get(msg, "mid")

    cond do
      not is_binary(mid) or mid == "" ->
        {:error, :missing_mid}

      Map.get(msg, "end_of_candidates") == true ->
        {:ok, %{end_of_candidates: true, mid: mid}}

      Map.has_key?(msg, "candidate") and is_nil(Map.get(msg, "candidate")) ->
        {:ok, %{end_of_candidates: true, mid: mid}}

      is_binary(Map.get(msg, "candidate")) and Map.get(msg, "candidate") != "" ->
        line = strip_a_prefix(Map.get(msg, "candidate"))
        info = %{candidate: line, mid: mid}

        info =
          case Map.get(msg, "sdpMLineIndex") || Map.get(msg, "mline_index") do
            idx when is_integer(idx) -> Map.put(info, :mline_index, idx)
            _ -> info
          end

        {:ok, info}

      # Firefox may send candidate: "" for end-of-candidates instead of null.
      is_binary(Map.get(msg, "candidate")) and Map.get(msg, "candidate") == "" ->
        {:ok, %{end_of_candidates: true, mid: mid}}

      true ->
        {:error, :missing_candidate}
    end
  end

  defp strip_a_prefix(<<"a=", rest::binary>>), do: rest
  defp strip_a_prefix(line) when is_binary(line), do: line

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  defp auth_ctx!(msg, state) do
    case auth_from_msg(msg, state) do
      {:ok, ctx} -> ctx
      _ -> nil
    end
  end

  defp auth_from_msg(msg, state) do
    token = Map.get(msg, "token") || Map.get(state.query, "token")
    tenant = Map.get(msg, "tenant_id") || Map.get(state.query, "tenant_id")
    session = Map.get(msg, "session_id") || Map.get(state.query, "session_id")

    participant =
      Map.get(msg, "participant_id") || Map.get(state.query, "participant_id")

    case Auth.auth_mode() do
      :lab ->
        if is_binary(tenant) and tenant != "" and is_binary(session) and session != "" do
          {:ok,
           %Context{
             tenant_id: tenant,
             session_id: session,
             participant_id: participant || "p1",
             capabilities: []
           }}
        else
          {:error, :unauthorized}
        end

      mode when mode in [:hmac, :jwt] ->
        secret_or_verify(token, tenant, session, participant)
    end
  end

  defp secret_or_verify(token, tenant, session, participant)
       when is_binary(token) and token != "" do
    case Auth.auth_mode() do
      :hmac ->
        with {:ok, ctx} <- Auth.verify_hmac_token(token),
             true <- is_nil(tenant) or ctx.tenant_id == tenant,
             true <- is_nil(session) or ctx.session_id == session,
             :ok <- Auth.bind_participant(ctx.participant_id, participant) do
          {:ok, ctx}
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          {:error, :forbidden} -> {:error, :forbidden}
          _ -> {:error, :forbidden}
        end

      :jwt ->
        case Xylon.Control.Auth.JWT.verify(token) do
          {:ok, ctx} ->
            if (is_nil(tenant) or ctx.tenant_id == tenant) and
                 (is_nil(session) or ctx.session_id == session) do
              case Auth.bind_participant(ctx.participant_id, participant) do
                :ok -> {:ok, ctx}
                {:error, :forbidden} -> {:error, :forbidden}
              end
            else
              {:error, :forbidden}
            end

          _ ->
            {:error, :unauthorized}
        end
    end
  end

  defp secret_or_verify(_, _, _, _), do: {:error, :unauthorized}

  defp ensure_session(msg, %Context{} = ctx) do
    library =
      case Map.get(msg, "library") do
        lib when is_binary(lib) and lib != "" ->
          try do
            String.to_existing_atom(lib)
          rescue
            ArgumentError -> Xylon.default_backend()
          end

        _ ->
          Xylon.default_backend()
      end

    with {:ok, backend_opts} <- fetch_join_backend_opts(msg) do
      backend_opts =
        Keyword.put(backend_opts, :authorize, authorize_for_library(library, ctx.capabilities))

      case Xylon.Session.whereis(ctx.tenant_id, ctx.session_id) do
        pid when is_pid(pid) ->
          {:ok, pid}

        nil ->
          Signaling.start_session(ctx.tenant_id, ctx.session_id, library, backend_opts)
      end
    end
  end

  defp authorize_for_library(:datachannel, caps), do: Auth.datachannel_authorize(caps)
  defp authorize_for_library(_library, caps), do: Auth.backend_authorize(caps)

  defp fetch_join_backend_opts(msg) do
    case Map.get(msg, "backend_opts") do
      nil ->
        {:ok, []}

      map when is_map(map) ->
        Signaling.backend_opts_from_map(map)

      _ ->
        {:error, :bad_backend_opts}
    end
  end
end
