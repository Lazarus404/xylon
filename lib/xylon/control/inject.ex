defmodule Xylon.Control.Inject do
  @moduledoc """
  Server-originated datachannel publish orchestration.

  ## What problem this solves

  Backends and bots must push data into live rooms (chat, signals, overlays)
  without holding a browser PeerConnection. Inject authenticates via `Context`,
  checks ACL and quota, resolves `dest` through `Dest`, publishes via Datachannel
  or Session, and emits inject webhooks. `notice/4` sends moderation notices
  without ACL/quota gates.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API. Payload delivery uses SCTP
  datachannels negotiated in SDP (JSEP / [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264)).
  """

  alias Xylon.Control.{Acl, Auth, Context, Dest, Quota}

  @doc """
  Resolves dest, checks ACL/quota, publishes via Datachannel or Session.

  Returns `:ok` or `{:error, reason}` where reason is
  `:unauthorized | :forbidden | :not_found | :empty_dest | :rate_limited | :not_supported`.
  """
  @spec publish(Context.t(), binary(), term(), keyword()) :: :ok | {:error, atom()}
  def publish(%Context{} = ctx, payload, dest, opts \\ [])
      when is_binary(payload) and is_list(opts) do
    label = Keyword.get(opts, :label)

    with :ok <- inject_acl(ctx, label),
         :ok <- groups_send_acl(ctx, dest),
         :ok <- moderation_gate(ctx),
         :ok <- Quota.check_inject(ctx.tenant_id, ctx.session_id),
         {:ok, resolved} <- Dest.resolve(ctx.tenant_id, ctx.session_id, dest, ctx.participant_id),
         {:ok, session} <- fetch_session(ctx.tenant_id, ctx.session_id),
         pub_opts <- Keyword.put(publish_opts(label), :participant_id, ctx.participant_id),
         :ok <- do_publish(session, payload, resolved, pub_opts) do
      emit_inject(ctx, "inject.accepted", label)
      :ok
    else
      {:error, :empty_dest} = err ->
        emit_inject(ctx, "inject.rejected", label)
        err

      {:error, :bad_dest} ->
        emit_inject(ctx, "inject.rejected", label)
        {:error, :empty_dest}

      {:error, :rate_limited} = err ->
        Quota.emit_exceeded(ctx.tenant_id, ctx.session_id, "inject")
        emit_inject(ctx, "inject.rejected", label)
        err

      {:error, _reason} = err ->
        emit_inject(ctx, "inject.rejected", label)
        err
    end
  end

  @doc """
  Best-effort moderation notice inject to a participant (skips ACL/quota/mute gate).

  `action` is `:mute`, `:unmute`, `:ban`, `:unban`, or `:kick`. Always returns
  `:ok` to the caller; publish failures are ignored.
  """
  @spec notice(Context.t(), term(), atom(), keyword()) :: :ok
  def notice(%Context{} = ctx, target, action, opts \\ [])
      when action in [:mute, :unmute, :ban, :unban, :kick] do
    payload =
      Jason.encode!(%{
        "type" => "moderation.notice",
        "action" => Atom.to_string(action),
        "reason" => Keyword.get(opts, :reason),
        "from" => ctx.participant_id
      })

    dest = if target == :all, do: :all, else: [target]

    with {:ok, session} <- fetch_session(ctx.tenant_id, ctx.session_id),
         :ok <- do_publish(session, payload, dest, []) do
      :ok
    else
      _ -> :ok
    end
  end

  defp moderation_gate(%Context{} = ctx) do
    if Code.ensure_loaded?(Xylon.Control.Moderation) and
         function_exported?(Xylon.Control.Moderation, :blocked_inject?, 3) and
         Xylon.Control.Moderation.blocked_inject?(ctx.tenant_id, ctx.session_id, ctx.participant_id) do
      {:error, :forbidden}
    else
      :ok
    end
  end

  defp emit_inject(ctx, type, label) do
    Xylon.Control.Webhooks.emit(type, %{
      "tenant_id" => ctx.tenant_id,
      "session_id" => ctx.session_id,
      "participant_id" => ctx.participant_id,
      "label" => label
    })
  end

  defp inject_acl(ctx, label) do
    if Acl.allow_inject?(ctx, label), do: :ok, else: {:error, :forbidden}
  end

  defp groups_send_acl(ctx, dest) do
    if Acl.group_dest?(dest) do
      if Acl.allow_groups_send_dest?(ctx, dest), do: :ok, else: {:error, :forbidden}
    else
      :ok
    end
  end

  defp fetch_session(tenant_id, session_id) do
    case Xylon.Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp publish_opts(nil), do: []
  defp publish_opts(label) when is_binary(label), do: [label: label]

  defp do_publish(session, payload, dest, opts) do
    dc = Module.concat([Xylon, Datachannel])

    cond do
      Code.ensure_loaded?(dc) and function_exported?(dc, :publish, 4) ->
        case apply(dc, :publish, [session, payload, dest, opts]) do
          :ok -> :ok
          {:error, :unauthorized} -> {:error, :forbidden}
          {:error, reason} -> {:error, normalize_pub_error(reason)}
        end

      true ->
        case Xylon.Session.publish_datachannel(session, payload, dest, opts) do
          :ok -> :ok
          {:error, :unauthorized} -> {:error, :forbidden}
          {:error, reason} -> {:error, normalize_pub_error(reason)}
        end
    end
  end

  defp normalize_pub_error(:not_supported), do: :not_supported
  defp normalize_pub_error(:not_found), do: :not_found
  defp normalize_pub_error(_), do: :not_supported

  @doc "Topics helper used by HTTP for default label from topic name."
  @spec default_label(binary() | nil) :: binary() | nil
  def default_label(nil), do: nil

  def default_label(topic) when is_binary(topic) do
    Acl.label_for(topic) || topic
  end

  @doc false
  def control_enabled?, do: Auth.enabled?()
end
