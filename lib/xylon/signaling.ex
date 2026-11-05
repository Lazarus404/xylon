defmodule Xylon.Signaling do
  @moduledoc """
  Protocol-agnostic signaling facade for media sessions.

  ## What problem this solves

  Browsers, HTTP clients, and SIP endpoints each speak a different signaling
  dialect, but every path must create the same `{tenant_id, session_id}` room,
  run SDP offer/answer, trickle ICE, and tear down peers consistently.
  Adapters under `Xylon.Signaling.*` translate wire formats; this module is the
  single entry point they call into `Xylon.Session`.

  Adapters must not start XGW peers or localize SDP themselves. They pass raw
  SDP and participant ids here; session logic owns negotiation and media wiring.

  ## RFCs and related specs

  - [RFC 8829](https://www.rfc-editor.org/rfc/rfc8829) -- JSEP (HTTP/WebSocket adapters)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via [XSDP](https://github.com/Lazarus404/xsdp))
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP (via [XSIP](https://github.com/Lazarus404/xsip))
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket
  """

  alias Xylon.Session

  @doc """
  Starts a session under `{tenant_id, session_id}` with the default backend.

  Returns `{:ok, pid}` when the session GenServer starts, or `{:error, reason}`
  when the backend is not attached or the session already exists.
  """
  @spec start_session(term(), term()) :: {:ok, pid()} | {:error, term()}
  def start_session(tenant_id, session_id) do
    start_session(tenant_id, session_id, Xylon.default_backend(), [])
  end

  @doc """
  Starts a session with an explicit backend catalogue id (e.g. `:echo`, `:datachannel`).

  The id must have been registered via `Xylon.attach/1`.
  """
  @spec start_session(term(), term(), atom()) :: {:ok, pid()} | {:error, term()}
  def start_session(tenant_id, session_id, library_id) when is_atom(library_id) do
    start_session(tenant_id, session_id, library_id, [])
  end

  @doc """
  Starts a session with backend keyword opts forwarded to `Session.create/4`.

  Common opts: `:mode`, `:default_label`, `:labels`, `:subset`, `:subscribe_mode`,
  `:max_publishers`, `:require_publish_cap`, audio-level tuning, and `:authorize`
  (Control HMAC context).
  """
  @spec start_session(term(), term(), atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(tenant_id, session_id, library_id, opts)
      when is_atom(library_id) and is_list(opts) do
    opts = maybe_history_tap(tenant_id, session_id, library_id, opts)
    Session.create(tenant_id, session_id, library_id, opts)
  end

  @doc """
  Parses JSON `backend_opts` (string keys) into Session keyword opts.

  Accepted keys: `mode`, `default_label`, `labels`, `subset`,
  `subscribe_mode`, `max_publishers`, `require_publish_cap`, `audiolevel_events`,
  `audio_active_packets`, `audio_level_average`, `bitrate_cap`, `twcc_period_ms`,
  `fir_interval_ms`, `audio` (`"sfu"` | `"mcu"`), `video` (`"sfu"`),
  `mcu_max_participants`, `mcu_max_contributors`,
  `mcu_cascade`, `mcu_mix_mid`,
  `default_dest`, `rpc_router`, `state_coalesce`, `rate_limit`,
  `on_no_channel`, `codec` (`"json"` | `"msgpack"` | `"cbor"`).
  """
  @spec backend_opts_from_map(nil | map()) :: {:ok, keyword()} | {:error, :bad_backend_opts}
  def backend_opts_from_map(nil), do: {:ok, []}

  def backend_opts_from_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, []}, fn
      {"mode", value}, {:ok, acc} when is_binary(value) ->
        case mode_atom(value) do
          {:ok, atom} -> {:cont, {:ok, Keyword.put(acc, :mode, atom)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"codec", value}, {:ok, acc} when is_binary(value) ->
        case codec_module(value) do
          {:ok, mod} -> {:cont, {:ok, Keyword.put(acc, :codec, mod)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"default_label", value}, {:ok, acc} when is_binary(value) ->
        {:cont, {:ok, Keyword.put(acc, :default_label, value)}}

      {"labels", value}, {:ok, acc} when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          {:cont, {:ok, Keyword.put(acc, :labels, value)}}
        else
          {:halt, {:error, :bad_backend_opts}}
        end

      {"subset", value}, {:ok, acc} when is_list(value) ->
        {:cont, {:ok, Keyword.put(acc, :subset, value)}}

      {"default_dest", value}, {:ok, acc} when is_binary(value) ->
        case default_dest_atom(value) do
          {:ok, atom} -> {:cont, {:ok, Keyword.put(acc, :default_dest, atom)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"rpc_router", true}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :rpc_router, true)}}

      {"rpc_router", false}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :rpc_router, false)}}

      {"state_coalesce", true}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :state_coalesce, true)}}

      {"state_coalesce", false}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :state_coalesce, false)}}

      {"rate_limit", %{"max_per_sec" => max, "burst" => burst}}, {:ok, acc}
      when is_integer(max) and max > 0 and is_integer(burst) and burst > 0 ->
        {:cont, {:ok, Keyword.put(acc, :rate_limit, {:token_bucket, max, burst})}}

      {"on_no_channel", "skip"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :on_no_channel, :skip)}}

      {"on_no_channel", "buffer"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :on_no_channel, :buffer)}}

      {"subscribe_mode", value}, {:ok, acc} when is_binary(value) ->
        case subscribe_mode_atom(value) do
          {:ok, atom} -> {:cont, {:ok, Keyword.put(acc, :subscribe_mode, atom)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"max_publishers", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :max_publishers, value)}}

      {"audiolevel_events", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :audiolevel_events, value)}}

      {"audio_active_packets", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :audio_active_packets, value)}}

      {"audio_level_average", value}, {:ok, acc}
      when is_integer(value) and value > 0 and value <= 127 ->
        {:cont, {:ok, Keyword.put(acc, :audio_level_average, value)}}

      {"bitrate_cap", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :bitrate_cap, value)}}

      {"twcc_period_ms", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :twcc_period_ms, value)}}

      {"fir_interval_ms", value}, {:ok, acc} when is_integer(value) and value >= 0 ->
        {:cont, {:ok, Keyword.put(acc, :fir_interval_ms, value)}}

      {"require_publish_cap", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :require_publish_cap, value)}}

      {"audio", value}, {:ok, acc} when is_binary(value) ->
        case media_strategy_atom(value) do
          {:ok, atom} -> {:cont, {:ok, Keyword.put(acc, :audio, atom)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"video", value}, {:ok, acc} when is_binary(value) ->
        case video_strategy_atom(value) do
          {:ok, atom} -> {:cont, {:ok, Keyword.put(acc, :video, atom)}}
          :error -> {:halt, {:error, :bad_backend_opts}}
        end

      {"mcu_max_participants", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :mcu_max_participants, value)}}

      {"mcu_max_contributors", value}, {:ok, acc} when is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, :mcu_max_contributors, value)}}

      {"mcu_cascade", "hub"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_cascade, :hub)}}

      {"mcu_cascade", "spoke"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_cascade, :spoke)}}

      {"mcu_mix_mid", value}, {:ok, acc} when is_binary(value) and byte_size(value) > 0 ->
        {:cont, {:ok, Keyword.put(acc, :mcu_mix_mid, value)}}

      {"mcu_cascade_trunk_profile", "opus"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_cascade_trunk_profile, :opus)}}

      {"mcu_cascade_trunk_profile", "pcm"}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_cascade_trunk_profile, :pcm)}}

      {"mcu_spoke_mix_minus", true}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_spoke_mix_minus, true)}}

      {"mcu_spoke_mix_minus", false}, {:ok, acc} ->
        {:cont, {:ok, Keyword.put(acc, :mcu_spoke_mix_minus, false)}}

      _, _ ->
        {:halt, {:error, :bad_backend_opts}}
    end)
  end

  def backend_opts_from_map(_), do: {:error, :bad_backend_opts}

  defp media_strategy_atom("sfu"), do: {:ok, :sfu}
  defp media_strategy_atom("mcu"), do: {:ok, :mcu}
  defp media_strategy_atom(_), do: :error

  defp video_strategy_atom("sfu"), do: {:ok, :sfu}
  defp video_strategy_atom(_), do: :error

  defp mode_atom("fanout_except_sender"), do: {:ok, :fanout_except_sender}
  defp mode_atom("fanout_all"), do: {:ok, :fanout_all}
  defp mode_atom("fanout_subset"), do: {:ok, :fanout_subset}
  defp mode_atom("mfu"), do: {:ok, :mfu}
  defp mode_atom(_), do: :error

  defp codec_module("json"), do: {:ok, Xylon.Datachannel.Codec.JSON}
  defp codec_module("msgpack"), do: {:ok, Xylon.Datachannel.Codec.Msgpack}
  defp codec_module("cbor"), do: {:ok, Xylon.Datachannel.Codec.Cbor}
  defp codec_module(_), do: :error

  defp default_dest_atom("except_sender"), do: {:ok, :except_sender}
  defp default_dest_atom("all"), do: {:ok, :all}
  defp default_dest_atom(_), do: :error

  defp subscribe_mode_atom("mesh"), do: {:ok, :mesh}
  defp subscribe_mode_atom("manual"), do: {:ok, :manual}
  defp subscribe_mode_atom(_), do: :error

  defp maybe_history_tap(tenant_id, session_id, library_id, opts) do
    control? =
      Code.ensure_loaded?(Xylon.Control.Auth) and Xylon.Control.Auth.enabled?()

    if control? and library_id == :datachannel and not Keyword.has_key?(opts, :tap) and
         Code.ensure_loaded?(Xylon.Control.History) do
      Keyword.put(opts, :tap, Xylon.Control.History.tap_fun(tenant_id, session_id))
    else
      opts
    end
  end

  @doc """
  Applies a remote SDP offer on an existing session and returns the answer SDP.

  Creates or reuses a participant peer when `participant_id` is omitted and the
  session is empty; multi-party sessions require `participant_id` in the 4-arity call.
  """
  @spec apply_remote_offer(term(), term(), binary()) :: {:ok, binary()} | {:error, term()}
  def apply_remote_offer(tenant_id, session_id, sdp) when is_binary(sdp) do
    apply_remote_offer(tenant_id, session_id, sdp, [])
  end

  @doc """
  Applies a remote SDP offer with per-participant opts.

  Accepted opts include `participant_id:` and `ice_mode:` (`:lite` or `:full`).
  """
  @spec apply_remote_offer(term(), term(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def apply_remote_offer(tenant_id, session_id, sdp, opts)
      when is_binary(sdp) and is_list(opts) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.apply_offer(pid, sdp, opts)
    end
  end

  @doc """
  Subscribes `subscriber_id` to `publisher_id`'s track at SDP `mid`.
  """
  @spec subscribe(term(), term(), term(), term(), binary(), keyword()) ::
          :ok | {:error, term()}
  def subscribe(tenant_id, session_id, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.subscribe(pid, subscriber_id, publisher_id, mid, opts)
    end
  end

  @doc """
  Subscribes `subscriber_id` to every published mid on `publisher_id`.
  """
  @spec subscribe_all(term(), term(), term(), term(), keyword()) :: :ok | {:error, term()}
  def subscribe_all(tenant_id, session_id, subscriber_id, publisher_id, opts \\ [])
      when is_list(opts) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.subscribe_all(pid, subscriber_id, publisher_id, opts)
    end
  end

  @doc """
  Removes a subscribe route on an existing session.
  """
  @spec unsubscribe(term(), term(), term(), term(), binary()) :: :ok | {:error, term()}
  def unsubscribe(tenant_id, session_id, subscriber_id, publisher_id, mid)
      when is_binary(mid) and mid != "" do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.unsubscribe(pid, subscriber_id, publisher_id, mid)
    end
  end

  @doc """
  Stops publishing selected mids for `participant_id` without leaving the session.

  `mids` is `:all` or a nonempty list of SDP mid strings.
  """
  @spec unpublish(term(), term(), term(), :all | [binary()]) :: :ok | {:error, term()}
  def unpublish(tenant_id, session_id, participant_id, mids \\ :all)
      when mids == :all or is_list(mids) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.unpublish(pid, participant_id, mids)
    end
  end

  @doc """
  Switches `subscriber_id` to `to_publisher_id` for `mid` (no renegotiation).
  """
  @spec switch(term(), term(), term(), term(), binary()) :: :ok | {:error, term()}
  def switch(tenant_id, session_id, subscriber_id, to_publisher_id, mid)
      when is_binary(mid) and mid != "" do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.switch(pid, subscriber_id, to_publisher_id, mid)
    end
  end

  @doc """
  Changes simulcast / SVC layer opts for an existing subscription.

  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`, and/or
  `:temporal_layer`.
  """
  @spec set_substream(term(), term(), term(), term(), binary(), keyword()) ::
          :ok | {:error, term()}
  def set_substream(tenant_id, session_id, subscriber_id, publisher_id, mid, opts \\ [])
      when is_binary(mid) and mid != "" and is_list(opts) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.set_substream(pid, subscriber_id, publisher_id, mid, opts)
    end
  end

  @doc """
  Replaces all subscribe routes for `subscriber_id` from `streams`.
  """
  @spec update_subscriptions(term(), term(), term(), [map()]) :: :ok | {:error, term()}
  def update_subscriptions(tenant_id, session_id, subscriber_id, streams)
      when is_list(streams) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.update_subscriptions(pid, subscriber_id, streams)
    end
  end

  @doc """
  Trickles a remote ICE candidate for a participant (inbound Trickle ICE).

  See `Xylon.Session.add_remote_candidate/3`.
  """
  @spec add_remote_candidate(term(), term(), term(), map()) :: :ok | {:error, term()}
  def add_remote_candidate(tenant_id, session_id, participant_id, info)
      when is_map(info) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.add_remote_candidate(pid, participant_id, info)
    end
  end

  @doc """
  Tears down all peers and stops the session GenServer.

  Idempotent for SIP BYE and WebSocket disconnect cleanup paths.
  """
  @spec hangup(term(), term()) :: :ok | {:error, :not_found}
  def hangup(tenant_id, session_id) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.hangup(pid)
    end
  end

  @doc """
  Removes one participant from the Session (closes their Peer).

  Idempotent if the participant is already gone. Returns `{:error, :not_found}`
  when the Session does not exist.
  """
  @spec leave(term(), term(), term()) :: :ok | {:error, :not_found}
  def leave(tenant_id, session_id, participant_id) do
    case Session.whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> Session.leave_participant(pid, participant_id)
    end
  end
end
