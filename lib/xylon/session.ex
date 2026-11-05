defmodule Xylon.Session do
  @moduledoc """
  One call or room: participants, signaling, and a single attached backend.

  ## What problem this solves

  A video call or conference room is more than one browser tab talking to a
  socket. Each participant must exchange connection details (SDP), discover
  network paths (ICE), encrypt media (DTLS-SRTP), and then send audio/video/data.
  `Xylon.Session` is the server-side container for that work: it creates an
  [XGW](https://github.com/Lazarus404/xgw) Listener and Peer per participant,
  builds an SDP answer with [XSDP](https://github.com/Lazarus404/xsdp), notifies
  the attached `Xylon.Backend` when someone joins or leaves, and keeps control
  events (ICE trickle, datachannel open/close, SCTP, peer closed) in one place.

  Steady-state RTP, RTCP, and datachannel **payloads** are handled by
  `Xylon.Forwarder` (registered as the Peer `handler:`), not this GenServer's
  mailbox, so media forwarding stays off the session control path.

  ## RFCs and related specs

  - W3C/IETF **JSEP** -- remote offer in, local answer out (`apply_offer/3`)
  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (XSDP)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE (`add_remote_candidate/3`)
  - [RFC 8838](https://www.rfc-editor.org/rfc/rfc8838) -- ICE trickle
  - [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764) -- DTLS-SRTP (XGW Peer)
  - SCTP datachannels -- negotiated in SDP; payload events forwarded to Backend
  """
  use GenServer

  require Logger

  alias XGW.{Listener, Peer}
  alias XMediaLib.SDP
  alias XMediaLib.SDP.{Fingerprint, Media, RtcpFb}
  alias Xylon.{Catalogue, Forwarder, Participant, Recording}
  alias Xylon.Recording.Aggregator
  alias Xylon.Recording.Cluster, as: RecordingCluster
  alias Xylon.Recording.Ctx
  alias Xylon.Recording.Registry, as: RecordingRegistry

  @recording_aggregate_timeout_ms 30_000

  @audio_level_uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  @transport_cc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"

  @echo_caps %{
    codecs: [
      %{name: "opus", clock_rate: 48_000, encoding_params: "2"},
      %{name: "VP8", clock_rate: 90_000}
    ],
    max_message_size: 262_144,
    # Echo does not send RTCP feedback; advertising nack/pli causes Chrome to wait on us.
    rtcp_fb: []
  }

  @conference_rtcp_fb [
    %RtcpFb{payload_type: "*", type: "nack"},
    %RtcpFb{payload_type: "*", type: "nack", parameters: "pli"},
    %RtcpFb{payload_type: "*", type: "ccm", parameters: "fir"},
    %RtcpFb{payload_type: "*", type: "goog-remb"},
    %RtcpFb{payload_type: "*", type: "transport-cc"}
  ]

  @conference_caps @echo_caps
                   |> Map.put(:extmaps, [@audio_level_uri, @transport_cc_uri, @rid_uri])
                   |> Map.put(:rtcp_fb, @conference_rtcp_fb)

  # Alphanumeric only. RFC 5245 also allows "+" / "/", but those have bitten
  # intermediaries that treat "+" as space; keep the safe subset for answers.
  @ice_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

  @doc """
  Default XSDP capability map for Echo lab sessions.

  Includes Opus audio, VP8 video, SCTP max message size, and no RTCP feedback
  attributes (Echo does not send NACK/PLI; advertising them makes Chrome wait).
  """
  @spec echo_capabilities() :: map()
  def echo_capabilities, do: @echo_caps

  defp default_capabilities(:conference), do: @conference_caps
  defp default_capabilities(_), do: @echo_caps

  @typedoc """
  Session GenServer state (`%Xylon.Session{}`).

  ## Fields

  - `:tenant_id` - Multi-tenant scope for registry lookup and Control hooks.
  - `:id` - Session identifier within the tenant (room or call id).
  - `:module_id` - Catalogue atom passed to `create/4` (e.g. `:echo`).
  - `:backend` - Resolved backend module from `Xylon.Catalogue`.
  - `:backend_state` - Opaque state returned by `Backend.init/2` and updated on
    join/leave and optional subscribe/moderation callbacks.
  - `:forwarder` - `Xylon.Forwarder` pid handling RTP/RTCP/datachannel for all
    peers in this session; `nil` only before init completes.
  - `:participants` - Map of participant id to `%Xylon.Participant{}`.
  - `:closed?` - Set when the last participant leaves and `Backend.terminate/2`
    has run; avoids double terminate on GenServer shutdown.
  - `:recording` - Lightweight active recording metadata (`recording_id`,
    `sequence`, `preceded_by`, `mode`) or `nil`. Per-packet handler state lives
    in `Xylon.Recording.Registry`, not here.
  - `:recording_seq` - Last assigned segment sequence (0 before first start).
  - `:last_recording_id` - Prior segment id for `preceded_by` on the next start.
  """
  @type t :: %__MODULE__{
          tenant_id: term(),
          id: term(),
          module_id: atom(),
          backend: module(),
          backend_state: term(),
          forwarder: pid() | nil,
          participants: %{optional(term()) => Participant.t()},
          closed?: boolean(),
          recording: map() | nil,
          recording_seq: non_neg_integer(),
          last_recording_id: binary() | nil
        }

  defstruct tenant_id: nil,
            id: nil,
            module_id: nil,
            backend: nil,
            backend_state: nil,
            forwarder: nil,
            participants: %{},
            closed?: false,
            recording: nil,
            recording_seq: 0,
            last_recording_id: nil

  @doc """
  Registry via-tuple for locating this session under `{tenant_id, session_id}`.
  """
  @spec via(term(), term()) :: {:via, Registry, {Xylon.Registry, {term(), term()}}}
  def via(tenant_id, session_id) do
    {:via, Registry, {Xylon.Registry, {tenant_id, session_id}}}
  end

  @doc """
  Returns the Session pid registered for `tenant_id` and `session_id`, or `nil`.
  """
  @spec whereis(term(), term()) :: pid() | nil
  def whereis(tenant_id, session_id) do
    case Registry.lookup(Xylon.Registry, {tenant_id, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Starts a Session under `Xylon.SessionSupervisor` for catalogue id `module_id`.

  Returns `{:error, :not_attached}` when `module_id` is not in the catalogue,
  `{:error, :already_exists}` when a session with the same tenant/id is running,
  `{:error, :not_accepting}` when this node is draining, or `{:ok, pid}` on
  success. Extra `opts` are forwarded to Backend init and Forwarder start
  (mode, labels, tap, etc.).
  """
  @spec create(term(), term(), atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create(tenant_id, session_id, module_id, opts \\ [])
      when is_atom(module_id) and is_list(opts) do
    case whereis(tenant_id, session_id) do
      pid when is_pid(pid) ->
        {:error, :already_exists}

      nil ->
        if Xylon.Cluster.Accepting.accepting?() do
          do_create(tenant_id, session_id, module_id, opts)
        else
          {:error, :not_accepting}
        end
    end
  end

  defp do_create(tenant_id, session_id, module_id, opts) do
    case Catalogue.fetch(module_id) do
      :error ->
        {:error, :not_attached}

      {:ok, backend} ->
        child_opts =
          Keyword.merge(opts,
            tenant_id: tenant_id,
            session_id: session_id,
            module_id: module_id,
            backend: backend
          )

        spec = %{
          id: {__MODULE__, tenant_id, session_id},
          start: {__MODULE__, :start_link, [child_opts]},
          restart: :temporary,
          type: :worker
        }

        case DynamicSupervisor.start_child(Xylon.SessionSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, _pid}} -> {:error, :already_exists}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Returns the Forwarder pid for this session, or `nil` if state is unavailable.
  """
  @spec forwarder(pid()) :: pid() | nil
  def forwarder(session) when is_pid(session) do
    case :sys.get_state(session) do
      %{forwarder: fwd} -> fwd
      _ -> nil
    end
  end

  @doc """
  Returns `plan_ref` from backend state when the backend stores one (SFU plans).

  Useful for control or tests that need the backend's routing handle.
  """
  @spec plan_ref(pid()) :: term() | nil
  def plan_ref(session) when is_pid(session) do
    case :sys.get_state(session) do
      %{backend_state: %{plan_ref: ref}} -> ref
      _ -> nil
    end
  end

  @doc """
  Sets a per-sender datachannel egress route when the catalogue backend supports it.

  Delegates to `Xylon.Datachannel.set_route/4`. See that module for dest shapes
  and precedence vs client `"to"`.
  """
  @spec set_egress_route(pid(), term(), :all | :except_sender | [term()], keyword()) ::
          :ok | {:error, term()}
  def set_egress_route(session, sender_id, dest, opts \\ [])
      when is_pid(session) and is_list(opts) do
    dc = Module.concat([Xylon, Datachannel])

    if Code.ensure_loaded?(dc) and function_exported?(dc, :set_route, 4) do
      apply(dc, :set_route, [session, sender_id, dest, opts])
    else
      {:error, :not_supported}
    end
  end

  @doc "Clears a per-sender egress route (see `Xylon.Datachannel.clear_route/3`)."
  @spec clear_egress_route(pid(), term(), keyword()) :: :ok | {:error, term()}
  def clear_egress_route(session, sender_id, opts \\ [])
      when is_pid(session) and is_list(opts) do
    dc = Module.concat([Xylon, Datachannel])

    if Code.ensure_loaded?(dc) and function_exported?(dc, :clear_route, 3) do
      apply(dc, :clear_route, [session, sender_id, opts])
    else
      {:error, :not_supported}
    end
  end

  @doc """
  Accepts a remote SDP offer and returns a local SDP answer.

  Starts an [XGW](https://github.com/Lazarus404/xgw) Listener and Peer for a
  new participant, negotiates codecs via [XSDP](https://github.com/Lazarus404/xsdp),
  embeds ICE and DTLS fingerprint in the answer, installs the Forwarder plan,
  and calls `Backend.participant_joined/2`.

  ## Options

  - `:participant_id` - Id for the new participant (default `"p1"`).
  - `:capabilities` - XSDP capability map (default Echo or conference caps).
  - `:ice_mode` - `:lite` (default) or `:full`. Full ICE omits `a=ice-lite`,
    starts the Peer with `ice_lite: false`, and merges STUN/TURN on the Listener.
    HTTP/SIP signaling stays ICE-lite. Control WebSocket may pass `:full` when
    `Xylon.Ice.full?/0`.

  Returns `{:error, :participant_exists}` if `participant_id` is already in the
  session. Timeout: 30 seconds.
  """
  @spec apply_offer(pid(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def apply_offer(session, offer_sdp, opts \\ [])
      when is_pid(session) and is_binary(offer_sdp) and is_list(opts) do
    GenServer.call(session, {:apply_offer, offer_sdp, opts}, 30_000)
  end

  @doc """
  Sends a datachannel payload from the server through the backend.

  Requires `Backend.publish_datachannel/4`. `dest` is `:all` or a list of
  participant ids. Options may include `:label`. The backend returns
  `{:forward_dc, specs, state}` tuples that Session delivers via XGW.
  """
  @spec publish_datachannel(pid(), binary(), :all | [term()], keyword()) ::
          :ok | {:error, term()}
  def publish_datachannel(session, payload, dest, opts \\ [])
      when is_pid(session) and is_binary(payload) and is_list(opts) do
    GenServer.call(session, {:publish_datachannel, payload, dest, opts})
  end

  @doc """
  Subscribes one participant to another's track at SDP `mid` (SFU backends).

  Requires `Backend.subscribe/5`. Passes `:forwarder` in opts for plan updates.
  """
  @spec subscribe(pid(), term(), term(), binary(), keyword()) :: :ok | {:error, term()}
  def subscribe(session, subscriber_id, publisher_id, mid, opts \\ [])
      when is_pid(session) and is_binary(mid) and mid != "" and is_list(opts) do
    GenServer.call(session, {:subscribe, subscriber_id, publisher_id, mid, opts})
  end

  @doc """
  Subscribes one participant to every published mid on `publisher_id`.

  Requires `Backend.subscribe_all/4`. Feed-all form of selective subscribe.
  """
  @spec subscribe_all(pid(), term(), term(), keyword()) :: :ok | {:error, term()}
  def subscribe_all(session, subscriber_id, publisher_id, opts \\ [])
      when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:subscribe_all, subscriber_id, publisher_id, opts})
  end

  @doc """
  Removes a subscribe route for `mid` between subscriber and publisher.

  Requires `Backend.unsubscribe/5`.
  """
  @spec unsubscribe(pid(), term(), term(), binary()) :: :ok | {:error, term()}
  def unsubscribe(session, subscriber_id, publisher_id, mid)
      when is_pid(session) and is_binary(mid) and mid != "" do
    GenServer.call(session, {:unsubscribe, subscriber_id, publisher_id, mid})
  end

  @doc """
  Stops publishing selected mids without removing the participant.

  Requires `Backend.unpublish/4`. `mids` defaults to `:all` (every published mid).
  Distinct from `moderate_av/4` (pause) and from leave.
  """
  @spec unpublish(pid(), term(), :all | [binary()]) :: :ok | {:error, term()}
  def unpublish(session, participant_id, mids \\ :all)
      when is_pid(session) and (mids == :all or is_list(mids)) do
    GenServer.call(session, {:unpublish, participant_id, mids})
  end

  @doc """
  Switches an existing subscription to a different publisher without renegotiation.

  Requires an active subscription for `mid` and backend `switch/5`.
  """
  @spec switch(pid(), term(), term(), binary()) :: :ok | {:error, term()}
  def switch(session, subscriber_id, to_publisher_id, mid)
      when is_pid(session) and is_binary(mid) and mid != "" do
    GenServer.call(session, {:switch, subscriber_id, to_publisher_id, mid})
  end

  @doc """
  Changes simulcast / SVC layer opts for a subscription.

  Requires `Backend.set_substream/5`. Passes `:forwarder` in opts for plan updates.
  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`, and/or
  `:temporal_layer`.
  """
  @spec set_substream(pid(), term(), term(), binary(), keyword()) :: :ok | {:error, term()}
  def set_substream(session, subscriber_id, publisher_id, mid, opts \\ [])
      when is_pid(session) and is_binary(mid) and mid != "" and is_list(opts) do
    GenServer.call(session, {:set_substream, subscriber_id, publisher_id, mid, opts})
  end

  @doc """
  Mutes or unmutes a publisher's outbound routes for selected mids.

  Requires backend `moderate_av/5`. `mids` defaults to `nil` (all published mids).
  Returns `:ok` without error when the backend does not implement moderation (no-op).
  """
  @spec moderate_av(pid(), term(), :mute | :unmute, [binary()] | nil) :: :ok | {:error, term()}
  def moderate_av(session, publisher_id, action, mids \\ nil)
      when is_pid(session) and action in [:mute, :unmute] and
             (is_nil(mids) or is_list(mids)) do
    GenServer.call(session, {:moderate_av, publisher_id, action, mids})
  end

  @doc """
  Starts a recording segment on this Session.

  At most one live recording. Returns `{:error, :conflict}` when already active.
  Options may include `:mode` (`:tracks` | `:tracks_and_mix`). When `mode` is
  omitted, auto-selects `:tracks_and_mix` if `backend_state.audio == :mcu`
  (Conference MCU path only; spoke SFU of hub mix with `audio: :sfu` stays
  `:tracks`), otherwise `:tracks`. Explicit `mode` always wins. Optional
  `:video_layer` / `:rid` are forwarded to the recording handler (SIM / SVC pin
  when using `XylonRecord.Handler`).

  On success returns a map with `:recording_id`, `:sequence`, `:preceded_by`, and
  `:mode`.
  """
  @spec start_recording(pid(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def start_recording(session, opts \\ []) when is_pid(session) do
    GenServer.call(session, {:start_recording, normalize_recording_opts(opts)})
  end

  @doc """
  Stops the active recording segment.

  Returns `{:ok, %{recording_id: id, status: "finalizing"}}` or
  `{:error, :not_found}` when none is active.
  """
  @spec stop_recording(pid()) :: {:ok, map()} | {:error, term()}
  def stop_recording(session) when is_pid(session) do
    GenServer.call(session, :stop_recording, @recording_aggregate_timeout_ms + 5_000)
  end

  @doc """
  Starts a recording segment on this node using shared coordinator context.

  Called via `:erpc` from `Xylon.Recording.Cluster.broadcast_start/3`. Uses the
  coordinator's `recording_id` / `sequence` / `preceded_by` / `mode`.
  """
  @spec recording_remote_start(term(), term(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def recording_remote_start(tenant_id, session_id, ctx_fields, opts)
      when is_map(ctx_fields) and is_map(opts) do
    case whereis(tenant_id, session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:recording_remote_start, ctx_fields, opts})
    end
  end

  @doc """
  Stops the local segment and reports artifacts to the coordinator Aggregator.

  Called via `:erpc` from `Xylon.Recording.Cluster.broadcast_stop/3`. Does not
  emit a webhook locally.
  """
  @spec recording_remote_stop(term(), term(), binary(), node()) ::
          :ok | {:error, term()}
  def recording_remote_stop(tenant_id, session_id, recording_id, coordinator_node)
      when is_binary(recording_id) and is_atom(coordinator_node) do
    case whereis(tenant_id, session_id) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(
          pid,
          {:recording_remote_stop, recording_id, coordinator_node},
          @recording_aggregate_timeout_ms + 5_000
        )
    end
  end

  @doc """
  Returns the active recording metadata map, or `{:error, :not_found}`.
  """
  @spec get_recording(pid()) :: {:ok, map()} | {:error, :not_found}
  def get_recording(session) when is_pid(session) do
    GenServer.call(session, :get_recording)
  end

  @doc """
  If this Session is the multi-home recording coordinator, starts the segment on
  a late-joining cohost hub and adds it to Aggregator expected edges.
  """
  @spec maybe_include_cohost_recording(term(), term(), node()) :: :ok
  def maybe_include_cohost_recording(tenant_id, session_id, peer_node)
      when is_atom(peer_node) do
    case whereis(tenant_id, session_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:maybe_include_cohost_recording, peer_node})
    end
  end

  @doc """
  Replaces all subscribe routes for `subscriber_id` from `streams`.

  Each entry is `%{publisher_id: id, mid: mid}` or `%{publisher_id: id}` (all mids).
  Requires backend `update_subscriptions/4`.
  """
  @spec update_subscriptions(pid(), term(), [map()]) :: :ok | {:error, term()}
  def update_subscriptions(session, subscriber_id, streams)
      when is_pid(session) and is_list(streams) do
    GenServer.call(session, {:update_subscriptions, subscriber_id, streams})
  end

  @doc """
  Adds a trickled remote ICE candidate to the participant's Peer.

  See [RFC 8838](https://www.rfc-editor.org/rfc/rfc8838). `info` is an atom-key
  map for `XGW.Peer.add_remote_candidate/2`: `:candidate`, `:mid`, `:mline_index`,
  and/or `:end_of_candidates`.
  """
  @spec add_remote_candidate(pid(), term(), map()) :: :ok | {:error, term()}
  def add_remote_candidate(session, participant_id, info)
      when is_pid(session) and is_map(info) do
    GenServer.call(session, {:add_remote_candidate, participant_id, info})
  end

  @doc """
  Binds a Control WebSocket pid to a participant for outbound ICE events.

  Monitors `ws_pid` and clears the binding on process DOWN or participant leave.
  Replaces any prior signaling pid. Flushes any buffered `:pending_control_ice`
  messages to the new pid.
  """
  @spec bind_signaling(pid(), term(), pid()) :: :ok | {:error, term()}
  def bind_signaling(session, participant_id, ws_pid)
      when is_pid(session) and is_pid(ws_pid) do
    GenServer.call(session, {:bind_signaling, participant_id, ws_pid})
  end

  @doc """
  Stops all peers and listeners, terminates the backend, and stops this GenServer.

  Waits up to 5 seconds for the session process to exit after `GenServer.stop/1`.
  """
  @spec hangup(pid()) :: :ok
  def hangup(session) when is_pid(session) do
    ref = Process.monitor(session)
    GenServer.stop(session, :normal)

    receive do
      {:DOWN, ^ref, :process, ^session, _} -> :ok
    after
      5_000 -> :ok
    end
  end

  @doc """
  Removes one participant and tears down their Peer and Listener.

  Drops the Forwarder plan, calls `Backend.participant_left/2`, and notifies
  Control when enabled. Idempotent if the id is already absent. When this was
  the last participant, the Session stops (same outcome as Peer `:closed`).
  """
  @spec leave_participant(pid(), term(), keyword()) :: :ok
  def leave_participant(session, participant_id, opts \\ [])
      when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:leave_participant, participant_id, opts})
  end

  @doc """
  Attaches an already-built participant (e.g. trunk pipe) without SDP offer.

  Calls `Backend.participant_joined/2` and installs the Forwarder plan. Used by
  `Xylon.Trunk.Manager` for multi-home cascade. When Control is enabled, local
  (non-remote, non-trunk) attaches emit Membership + `participant.joined`;
  remote trunk announces do not.
  """
  @spec attach_participant(pid(), Participant.t()) :: :ok | {:error, term()}
  def attach_participant(session, %Participant{} = participant) when is_pid(session) do
    GenServer.call(session, {:attach_participant, participant})
  end

  @doc false
  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(tenant_id, session_id))
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    session_id = Keyword.fetch!(opts, :session_id)
    module_id = Keyword.fetch!(opts, :module_id)
    backend = Keyword.fetch!(opts, :backend)

    session = %__MODULE__{
      tenant_id: tenant_id,
      id: session_id,
      module_id: module_id,
      backend: backend
    }

    case backend.init(session, Keyword.put(opts, :session_pid, self())) do
      {:ok, backend_state} ->
        # Same backend keyword opts as Session init (mode, labels, tap, ...) so the
        # Forwarder's handle_* path does not silently fall back to defaults.
        {:ok, fwd} = Forwarder.start_link(Keyword.put(opts, :session, self()))
        state = %{session | backend_state: backend_state, forwarder: fwd}
        notify_control_created(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:apply_offer, offer_sdp, opts}, _from, state) do
    participant_id = Keyword.get(opts, :participant_id, "p1")

    if Map.has_key?(state.participants, participant_id) do
      {:reply, {:error, :participant_exists}, state}
    else
      case do_apply_offer(offer_sdp, opts, state) do
        {:ok, answer, new_state} -> {:reply, {:ok, answer}, new_state}
        {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:leave_participant, participant_id}, _from, state) do
    handle_call({:leave_participant, participant_id, []}, nil, state)
  end

  def handle_call({:leave_participant, participant_id, opts}, _from, state) when is_list(opts) do
    stop_if_empty = Keyword.get(opts, :stop_if_empty, true)

    case do_leave_participant(state, participant_id, stop_if_empty) do
      {:ok, state2} ->
        {:reply, :ok, state2}

      {:stop, state2} ->
        {:stop, :normal, :ok, state2}
    end
  end

  def handle_call({:attach_participant, %Participant{} = participant}, _from, state) do
    id = participant.id

    cond do
      Map.has_key?(state.participants, id) ->
        {:reply, {:error, :participant_exists}, state}

      true ->
        case state.backend.participant_joined(participant, state.backend_state) do
          {:ok, backend_state} ->
            case install_forward_plan(state, participant, backend_state) do
              {backend_state2, :ok} ->
                state2 = %{
                  state
                  | backend_state: backend_state2,
                    participants: Map.put(state.participants, id, participant)
                }

                # Local attaches (lab / bench) update Membership + webhooks.
                # Remote trunk announces stay off the SaaS lifecycle channel.
                if control_track_participant?(participant) do
                  notify_control_join(state2, participant)
                end

                {:reply, :ok, state2}

              {backend_state2, {:error, reason}} ->
                {:ok, backend_state3} =
                  state.backend.participant_left(participant, backend_state2)

                {:reply, {:error, reason}, %{state | backend_state: backend_state3}}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:publish_datachannel, payload, dest, opts}, _from, state) do
    backend = state.backend

    if function_exported?(backend, :publish_datachannel, 4) do
      case backend.publish_datachannel(payload, dest, opts, state.backend_state) do
        {:forward_dc, specs, backend_state} ->
          Forwarder.send_dc_specs(specs, backend_state)
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:subscribe, subscriber_id, publisher_id, mid, opts}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :subscribe, 5) do
      opts = Keyword.put(opts, :forwarder, state.forwarder)

      case backend.subscribe(subscriber_id, publisher_id, mid, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:subscribe_all, subscriber_id, publisher_id, opts}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :subscribe_all, 4) do
      opts = Keyword.put(opts, :forwarder, state.forwarder)

      case backend.subscribe_all(subscriber_id, publisher_id, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:unsubscribe, subscriber_id, publisher_id, mid}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :unsubscribe, 5) do
      opts = [forwarder: state.forwarder]

      case backend.unsubscribe(subscriber_id, publisher_id, mid, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:unpublish, participant_id, mids}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :unpublish, 4) do
      opts = [forwarder: state.forwarder]

      case backend.unpublish(participant_id, mids, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:switch, subscriber_id, to_publisher_id, mid}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :switch, 5) do
      opts = [forwarder: state.forwarder]

      case backend.switch(subscriber_id, to_publisher_id, mid, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:set_substream, subscriber_id, publisher_id, mid, opts}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :set_substream, 5) do
      opts = Keyword.put(opts, :forwarder, state.forwarder)

      case backend.set_substream(
             subscriber_id,
             publisher_id,
             mid,
             opts,
             state.backend_state
           ) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:moderate_av, publisher_id, action, mids}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :moderate_av, 5) do
      opts = [forwarder: state.forwarder]

      case backend.moderate_av(publisher_id, action, mids, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:start_recording, opts}, _from, state) when is_map(opts) do
    case do_start_recording(state, opts) do
      {:ok, info, new_state} -> {:reply, {:ok, info}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:stop_recording, _from, state) do
    case do_stop_recording(state) do
      {:ok, info, new_state} -> {:reply, {:ok, info}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:recording_remote_start, ctx_fields, opts}, _from, state)
      when is_map(ctx_fields) and is_map(opts) do
    case do_remote_start_recording(state, ctx_fields, opts) do
      {:ok, info, new_state} -> {:reply, {:ok, info}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:recording_remote_stop, recording_id, coordinator_node}, _from, state)
      when is_binary(recording_id) and is_atom(coordinator_node) do
    case do_remote_stop_recording(state, recording_id, coordinator_node) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:maybe_include_cohost_recording, peer_node}, _from, state)
      when is_atom(peer_node) do
    {:reply, :ok, maybe_include_cohost_recording_state(state, peer_node)}
  end

  def handle_call(:get_recording, _from, state) do
    case state.recording do
      nil ->
        {:reply, {:error, :not_found}, state}

      meta when is_map(meta) ->
        {:reply,
         {:ok,
          Map.drop(meta, [
            :started_at,
            :multi_home,
            :coordinator,
            :coordinator_node,
            :expected_edges,
            :layout,
            :rtmp_url
          ])}, state}
    end
  end

  def handle_call({:update_subscriptions, subscriber_id, streams}, _from, state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :update_subscriptions, 4) do
      opts = [forwarder: state.forwarder]

      case backend.update_subscriptions(subscriber_id, streams, opts, state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_supported}, state}
    end
  end

  def handle_call({:add_remote_candidate, participant_id, info}, _from, state) do
    case Map.get(state.participants, participant_id) do
      %Participant{peer_ref: peer} when is_pid(peer) ->
        {:reply, Peer.add_remote_candidate(peer, info), state}

      %Participant{} ->
        {:reply, {:error, :not_connected}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:bind_signaling, participant_id, ws_pid}, _from, state) do
    case Map.get(state.participants, participant_id) do
      %Participant{} = p ->
        demonitor_signaling(p)
        ref = Process.monitor(ws_pid)
        pending = Map.get(p.meta || %{}, :pending_control_ice, [])

        meta =
          (p.meta || %{})
          |> Map.merge(%{signaling_pid: ws_pid, signaling_ref: ref})
          |> Map.delete(:pending_control_ice)

        p = %{p | meta: meta}
        Enum.each(pending, fn payload -> send(ws_pid, {:xylon_control_ice, payload}) end)
        {:reply, :ok, %{state | participants: Map.put(state.participants, participant_id, p)}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # DC may open during Peer.apply_descriptions before the participant is in
  # state.participants. Retry so Plan.put_channel still runs.
  @dc_open_retry_ms 10
  @dc_open_retry_max 100

  @impl true
  def handle_info({:xgw, :datachannel, peer, info}, state) when is_map(info) do
    dispatch_datachannel_open(peer, info, state, 0)
  end

  def handle_info({:xylon_dc_open_retry, peer, info, attempt}, state)
      when is_map(info) and is_integer(attempt) do
    dispatch_datachannel_open(peer, info, state, attempt)
  end

  def handle_info({:xgw, :datachannel, _peer, _info}, state), do: {:noreply, state}

  def handle_info({:xgw, :datachannel_closed, peer, channel_ref}, state)
      when is_reference(channel_ref) do
    case participant_for_peer(state, peer) do
      nil ->
        {:noreply, state}

      participant ->
        backend = state.backend

        if function_exported?(backend, :handle_datachannel_closed, 3) do
          case backend.handle_datachannel_closed(participant, channel_ref, state.backend_state) do
            {:ok, backend_state} ->
              {:noreply, %{state | backend_state: backend_state}}

            other ->
              Logger.warning(
                "xylon session #{inspect(state.id)} handle_datachannel_closed unexpected=#{inspect(other)}"
              )

              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:xgw, :sctp_connected, peer}, state) do
    Logger.info("xylon session #{inspect(state.id)} SCTP connected")

    case participant_for_peer(state, peer) do
      nil ->
        {:noreply, state}

      participant ->
        backend = state.backend

        if function_exported?(backend, :maybe_server_open, 2) do
          case backend.maybe_server_open(participant, state.backend_state) do
            {:ok, backend_state} ->
              {:noreply, %{state | backend_state: backend_state}}

            other ->
              Logger.warning(
                "xylon session #{inspect(state.id)} maybe_server_open unexpected=#{inspect(other)}"
              )

              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:xgw, :sctp_disconnected, peer}, state) do
    Logger.info("xylon session #{inspect(state.id)} SCTP disconnected")

    case participant_for_peer(state, peer) do
      nil ->
        {:noreply, state}

      participant ->
        backend = state.backend

        if function_exported?(backend, :handle_sctp_disconnected, 2) do
          case backend.handle_sctp_disconnected(participant, state.backend_state) do
            {:ok, backend_state} ->
              {:noreply, %{state | backend_state: backend_state}}

            other ->
              Logger.warning(
                "xylon session #{inspect(state.id)} handle_sctp_disconnected unexpected=#{inspect(other)}"
              )

              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:xgw, :closed, peer, reason}, state) do
    case participant_for_peer(state, peer) do
      nil ->
        if is_pid(state.forwarder) do
          _ = Forwarder.remove_peer(state.forwarder, peer)
        end

        {:noreply, state}

      %Participant{id: id} ->
        case do_leave_participant(state, id, true, reason) do
          {:ok, state2} -> {:noreply, state2}
          {:stop, state2} -> {:stop, :normal, state2}
        end
    end
  end

  def handle_info({:xgw, :ice_connected, _peer}, state), do: {:noreply, state}
  def handle_info({:xgw, :dtls_connected, _peer}, state), do: {:noreply, state}

  def handle_info({:xgw, :local_candidate, peer, %{candidate: line, mid: mid}}, state)
      when is_binary(line) do
    payload = %{
      type: :ice,
      candidate: strip_a_prefix(line),
      sdpMid: mid,
      sdpMLineIndex: 0
    }

    {:noreply, deliver_or_buffer_control_ice(state, peer, payload)}
  end

  def handle_info({:xgw, :local_candidates_complete, peer}, state) do
    {:noreply, deliver_or_buffer_control_ice(state, peer, %{type: :ice_complete})}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    participants =
      Enum.reduce(state.participants, state.participants, fn {id, p}, acc ->
        if Map.get(p.meta || %{}, :signaling_ref) == ref or
             Map.get(p.meta || %{}, :signaling_pid) == pid do
          meta =
            (p.meta || %{})
            |> Map.delete(:signaling_pid)
            |> Map.delete(:signaling_ref)

          Map.put(acc, id, %{p | meta: meta})
        else
          acc
        end
      end)

    {:noreply, %{state | participants: participants}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = maybe_flush_recording(state)

    if is_pid(state.forwarder) and Process.alive?(state.forwarder) do
      _ = Forwarder.invalidate(state.forwarder)
      GenServer.stop(state.forwarder, :normal, 5_000)
    end

    Enum.each(state.participants, fn {_id, p} ->
      if is_pid(p.peer_ref) and Process.alive?(p.peer_ref) do
        _ = Peer.close(p.peer_ref)
      end

      stop_participant_listener(p)
    end)

    # Leave-empty path already terminated the backend and emitted session.closed.
    unless state.closed? do
      _ = state.backend.terminate(:shutdown, state.backend_state)
      notify_control_clear(state)
    end

    :ok
  end

  defp participant_for_peer(state, peer) do
    Enum.find_value(state.participants, fn {_id, p} ->
      if p.peer_ref == peer, do: p
    end)
  end

  defp dispatch_datachannel_open(peer, %{label: label, id: id} = info, state, attempt) do
    if attempt == 0 do
      Logger.info(
        "xylon session #{inspect(state.id)} datachannel open label=#{inspect(label)} id=#{id}"
      )
    end

    case participant_for_peer(state, peer) do
      nil when attempt < @dc_open_retry_max ->
        Process.send_after(
          self(),
          {:xylon_dc_open_retry, peer, info, attempt + 1},
          @dc_open_retry_ms
        )

        {:noreply, state}

      nil ->
        Logger.warning(
          "xylon session #{inspect(state.id)} datachannel open dropped: no participant for peer after #{@dc_open_retry_max} retries label=#{inspect(label)}"
        )

        {:noreply, state}

      participant ->
        apply_datachannel_open(participant, info, state)
    end
  end

  defp apply_datachannel_open(participant, %{ref: ref, label: label} = info, state) do
    backend = state.backend

    if function_exported?(backend, :handle_datachannel_open, 3) do
      open =
        Map.take(info, [:ref, :label, :id, :reliability, :order, :param])
        |> Map.put(:ref, ref)
        |> Map.put(:label, label)
        |> Map.put(:id, Map.get(info, :id))

      case backend.handle_datachannel_open(participant, open, state.backend_state) do
        {:ok, backend_state} ->
          {:noreply, %{state | backend_state: backend_state}}

        {:forward_dc, specs, backend_state} ->
          Forwarder.send_dc_specs(specs, backend_state)
          {:noreply, %{state | backend_state: backend_state}}

        other ->
          Logger.warning(
            "xylon session #{inspect(state.id)} handle_datachannel_open unexpected=#{inspect(other)}"
          )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp notify_control_created(state) do
    if control_membership?() do
      Xylon.Control.Webhooks.emit("session.created", control_lifecycle_payload(state))
    end

    :ok
  end

  defp notify_control_join(state, participant) do
    if control_membership?() do
      meta =
        Map.merge(participant.meta || %{}, %{
          role: participant.role,
          joined_at: System.system_time(:second)
        })

      Xylon.Control.Membership.join(state.tenant_id, state.id, participant.id, meta)

      if Process.whereis(Xylon.Control.Presence) do
        Xylon.Control.Presence.broadcast_diff(state.tenant_id, state.id, %{
          action: :join,
          participant_id: participant.id,
          role: Map.get(meta, :role),
          joined_at: Map.get(meta, :joined_at),
          meta: Map.drop(meta, [:role, :joined_at, "role", "joined_at"])
        })
      end

      Xylon.Control.Webhooks.emit(
        "participant.joined",
        control_lifecycle_payload(state, %{"participant_id" => participant.id})
      )
    end

    :ok
  end

  defp notify_control_leave(state, participant_id) do
    if control_membership?() do
      Xylon.Control.Membership.leave(state.tenant_id, state.id, participant_id)

      if Code.ensure_loaded?(Xylon.Control.Groups) do
        Xylon.Control.Groups.remove_participant(state.tenant_id, state.id, participant_id)
      end

      if Process.whereis(Xylon.Control.Presence) do
        Xylon.Control.Presence.broadcast_diff(state.tenant_id, state.id, %{
          action: :leave,
          participant_id: participant_id
        })
      end

      Xylon.Control.Webhooks.emit(
        "participant.left",
        control_lifecycle_payload(state, %{"participant_id" => participant_id})
      )
    end

    :ok
  end

  defp notify_control_clear(state) do
    if Code.ensure_loaded?(Xylon.Control.Feeds) do
      Xylon.Control.Feeds.clear(state.tenant_id, state.id)
    end

    if control_membership?() do
      Xylon.Control.Membership.clear(state.tenant_id, state.id)

      if Code.ensure_loaded?(Xylon.Control.Groups) do
        Xylon.Control.Groups.clear(state.tenant_id, state.id)
      end

      Xylon.Control.Webhooks.emit("session.closed", control_lifecycle_payload(state))
    end

    :ok
  end

  defp control_lifecycle_payload(state, extra \\ %{}) when is_map(extra) do
    Map.merge(
      %{
        "tenant_id" => state.tenant_id,
        "session_id" => state.id,
        "node" => Atom.to_string(Node.self()),
        "region" => Xylon.Cluster.local_region()
      },
      extra
    )
  end

  # SaaS lifecycle tracks local clients only. Remote trunk announces use
  # meta.remote / role :trunk and must not fan out join/leave webhooks.
  defp control_track_participant?(%Participant{role: :trunk}), do: false

  defp control_track_participant?(%Participant{meta: meta}) when is_map(meta) do
    Map.get(meta, :remote) != true and Map.get(meta, "remote") != true
  end

  defp control_track_participant?(_), do: true

  defp control_membership? do
    Code.ensure_loaded?(Xylon.Control.Membership) and
      Xylon.Control.Auth.enabled?()
  end

  defp max_participants_gate(state, participant_id) do
    if control_membership?() and is_pid(Process.whereis(Xylon.Control.Quota)) and
         not Map.has_key?(state.participants, participant_id) do
      count = map_size(Xylon.Control.Membership.list(state.tenant_id, state.id))

      case Xylon.Control.Quota.check_max_participants(state.tenant_id, state.id, count) do
        :ok ->
          :ok

        {:error, :rate_limited} = err ->
          Xylon.Control.Quota.emit_exceeded(state.tenant_id, state.id, "max_participants")
          err
      end
    else
      :ok
    end
  end

  defp deliver_or_buffer_control_ice(state, peer, payload) do
    case participant_for_peer(state, peer) do
      %Participant{meta: %{signaling_pid: pid}} when is_pid(pid) ->
        send(pid, {:xylon_control_ice, payload})
        state

      %Participant{id: id} = p ->
        pending = Map.get(p.meta || %{}, :pending_control_ice, []) ++ [payload]
        meta = Map.put(p.meta || %{}, :pending_control_ice, pending)
        %{state | participants: Map.put(state.participants, id, %{p | meta: meta})}

      _ ->
        state
    end
  end

  defp demonitor_signaling(%Participant{meta: %{signaling_ref: ref}}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp demonitor_signaling(_), do: :ok

  defp strip_a_prefix(<<"a=", rest::binary>>), do: rest
  defp strip_a_prefix(line) when is_binary(line), do: line

  defp do_apply_offer(offer_sdp, opts, state) do
    participant_id = Keyword.get(opts, :participant_id, "p1")
    caps = Keyword.get(opts, :capabilities, default_capabilities(state.module_id))
    ice_lite? = Keyword.get(opts, :ice_mode, :lite) != :full
    media_handler = state.forwarder || self()

    with :ok <- max_participants_gate(state, participant_id),
         {:ok, listener} <- start_listener(ice_lite?),
         fingerprint <- Listener.local_fingerprint(listener),
         {:ok, draft} <- XSDP.answer_offer(offer_sdp, capabilities: caps),
         {:ok, answer} <- localize_answer(draft, listener, fingerprint, ice_lite?),
         {:ok, peer} <-
           Peer.start_supervised(
             handler: media_handler,
             listener: listener,
             ice_lite: ice_lite?
           ) do
      case Peer.apply_descriptions(peer, offer_sdp, answer) do
        :ok ->
          participant = %Participant{
            id: participant_id,
            peer_ref: peer,
            listener: listener,
            role: :echo,
            meta: participant_meta(opts, ice_lite?)
          }

          case state.backend.participant_joined(participant, state.backend_state) do
            {:ok, backend_state} ->
              case install_forward_plan(state, participant, backend_state) do
                {backend_state, :ok} ->
                  case maybe_media_ready(
                         state,
                         participant,
                         offer_sdp,
                         backend_state
                       ) do
                    {:ok, backend_state2} ->
                      notify_control_join(state, participant)

                      {:ok, answer,
                       %{
                         state
                         | backend_state: backend_state2,
                           participants: Map.put(state.participants, participant_id, participant)
                       }}

                    {:error, reason} ->
                      {:ok, backend_state3} =
                        state.backend.participant_left(participant, backend_state)

                      _ = Peer.close(peer)
                      stop_pid(listener)
                      {:error, reason, %{state | backend_state: backend_state3}}
                  end

                {backend_state, {:error, reason}} ->
                  {:ok, backend_state3} =
                    state.backend.participant_left(participant, backend_state)

                  _ = Peer.close(peer)
                  stop_pid(listener)
                  {:error, reason, %{state | backend_state: backend_state3}}
              end

            {:error, reason} ->
              _ = Peer.close(peer)
              stop_pid(listener)
              {:error, reason}
          end

        {:error, reason} ->
          _ = Peer.close(peer)
          stop_pid(listener)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp start_listener(ice_lite?) do
    opts =
      [ip: {0, 0, 0, 0}, port: 0, include_loopback: true]
      |> Keyword.merge(Xylon.Ice.listener_opts!())

    opts =
      if ice_lite? do
        opts
      else
        Keyword.merge(opts, Xylon.Ice.stun_listener_opts())
      end

    Listener.start_link(opts)
  end

  # Drops one participant synchronously. Closes Peer after map removal so a later
  # `:closed` is a no-op. When `stop_if_empty` and no participants remain, returns
  # `{:stop, state}` for the GenServer to exit.
  defp do_leave_participant(state, participant_id, stop_if_empty, reason \\ :leave) do
    case Map.get(state.participants, participant_id) do
      nil ->
        {:ok, state}

      %Participant{} = participant ->
        peer = participant.peer_ref

        if is_pid(state.forwarder) and is_pid(peer) do
          _ = Forwarder.remove_peer(state.forwarder, peer)
        end

        backend = state.backend
        {:ok, backend_state} = backend.participant_left(participant, state.backend_state)

        demonitor_signaling(participant)
        schedule_stop_listener(participant.listener, peer)

        if control_track_participant?(participant) do
          notify_control_leave(state, participant.id)
        end

        # Peer may already be dead (:consent_failed / prior close); never crash Session.
        if is_pid(peer) do
          try do
            if Process.alive?(peer), do: Peer.close(peer)
          catch
            :exit, _ -> :ok
          end
        end

        participants = Map.delete(state.participants, participant_id)
        state = %{state | backend_state: backend_state, participants: participants}

        if participants == %{} and stop_if_empty do
          state = maybe_flush_recording(state)
          notify_control_clear(state)
          _ = backend.terminate(reason, backend_state)
          {:stop, %{state | closed?: true}}
        else
          {:ok, state}
        end
    end
  end

  defp schedule_stop_listener(listener, peer) when is_pid(listener) and is_pid(peer) do
    # Peer.close may still be using the Listener; stop only after Peer exits.
    spawn(fn ->
      ref = Process.monitor(peer)

      receive do
        {:DOWN, ^ref, :process, ^peer, _} -> :ok
      after
        5_000 -> :ok
      end

      stop_pid(listener)
    end)

    :ok
  end

  defp schedule_stop_listener(_, _), do: :ok

  defp stop_participant_listener(%Participant{listener: pid}) when is_pid(pid), do: stop_pid(pid)
  defp stop_participant_listener(_), do: :ok

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp install_forward_plan(%{forwarder: fwd, backend: backend} = _state, participant, backend_state)
       when is_pid(fwd) do
    if is_nil(participant.peer_ref) do
      {backend_state, :ok}
    else
      _ = Code.ensure_loaded(backend)

      cond do
        function_exported?(backend, :forward_plan, 2) ->
          case backend.forward_plan(participant, backend_state) do
            {:ok, plan, backend_state2} when is_map(plan) ->
              peer = participant.peer_ref
              _ = Forwarder.put_plan(fwd, peer, plan)
              {backend_state2, :ok}

            other ->
              Logger.warning(
                "xylon invalid forward_plan from=#{inspect(backend)} got=#{inspect(other)}"
              )

              {backend_state, {:error, {:invalid_forward_plan, other}}}
          end

        true ->
          _ = Forwarder.install_echo(fwd, participant)
          {backend_state, :ok}
      end
    end
  end

  defp install_forward_plan(_state, _participant, backend_state), do: {backend_state, :ok}

  defp maybe_media_ready(%{backend: backend, forwarder: fwd}, participant, offer_sdp, backend_state)
       when is_binary(offer_sdp) do
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :media_ready, 4) do
      ctx = %{forwarder: fwd}
      backend.media_ready(participant, offer_sdp, ctx, backend_state)
    else
      {:ok, backend_state}
    end
  end

  defp maybe_media_ready(_state, _participant, _offer_sdp, backend_state),
    do: {:ok, backend_state}

  defp participant_meta(opts, ice_lite?) when is_list(opts) do
    meta = %{ice_lite?: ice_lite?}

    case Keyword.fetch(opts, :control_capabilities) do
      {:ok, caps} -> Map.put(meta, :capabilities, caps)
      :error -> meta
    end
  end

  # XSDP negotiates codecs/setup from the offer; localize ICE/DTLS and host
  # candidates. ICE-lite answers advertise a=ice-lite; full-ICE omits it.
  defp localize_answer(draft_bin, listener, fingerprint_value, ice_lite?) do
    with {:ok, sdp} <- SDP.parse(draft_bin) do
      ufrag = random_ice_string(4)
      pwd = random_ice_string(22)
      port = Listener.port(listener)
      candidates = parse_host_candidates(Listener.host_candidate_lines(listener))
      fp = %Fingerprint{algorithm: "sha-256", value: fingerprint_value}

      media =
        Enum.map(sdp.media, fn
          %Media{port: 0} = m ->
            m

          %Media{} = m ->
            attrs =
              Enum.reject(m.attributes || [], fn
                {"ice-options", _} -> true
                _ -> false
              end)

            %{
              m
              | port: port,
                ice_ufrag: ufrag,
                ice_pwd: pwd,
                fingerprint: fp,
                setup: :passive,
                candidates: candidates,
                attributes: attrs
            }
        end)

      attrs =
        Enum.reject(sdp.attributes, fn
          {"fingerprint", _} -> true
          {"ice-lite", _} -> true
          # HTTP/SIP answers are non-trickle ICE-lite with host candidates already
          # in the SDP. Do not echo offer ice-options:trickle (Chrome may wait for
          # end-of-candidates that never arrives on this path).
          {"ice-options", _} -> ice_lite?
          _ -> false
        end)

      attrs = if ice_lite?, do: attrs ++ [{"ice-lite", true}], else: attrs

      sdp
      |> Map.put(:media, media)
      |> Map.put(:attributes, attrs)
      |> SDP.encode()
    end
  end

  defp parse_host_candidates(lines) do
    Enum.map(lines, fn line ->
      line
      |> String.replace_prefix("a=", "")
      |> String.replace_prefix("candidate:", "")
      |> XMediaLib.SDP.Parser.Helpers.parse_candidate()
    end)
  end

  defp random_ice_string(len) do
    1..len
    |> Enum.map(fn _ -> Enum.random(@ice_chars) end)
    |> List.to_string()
  end

  defp normalize_recording_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_recording_opts(opts) when is_map(opts), do: opts

  defp do_start_recording(%{recording: meta} = state, _opts) when is_map(meta) do
    {:error, :conflict, state}
  end

  defp do_start_recording(state, opts) do
    with :ok <- validate_recording_layout_opts(opts, state) do
      do_start_recording_validated(state, opts)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_start_recording_validated(state, opts) do
    mode = resolve_recording_mode(opts, state.backend_state)
    sequence = state.recording_seq + 1
    recording_id = mint_recording_id()
    preceded_by = state.last_recording_id
    started_at = System.system_time(:millisecond)
    key = {state.tenant_id, state.id}
    peers = RecordingCluster.peer_hubs(key)
    multi_home? = peers != []
    layout? = recording_layout?(opts)

    ctx = %Ctx{
      tenant_id: state.tenant_id,
      session_id: state.id,
      recording_id: recording_id,
      sequence: sequence,
      preceded_by: preceded_by,
      mode: mode,
      edge_node: Node.self()
    }

    handler = Recording.handler()

    start_opts =
      opts
      |> Map.drop([:mode, "mode"])
      |> Map.put(:plan_ref, self())
      |> then(fn o ->
        if layout?, do: Map.put(o, :layout, true), else: Map.delete(o, :layout) |> Map.delete("layout")
      end)

    case handler.on_start(ctx, start_opts) do
      {:ok, handler_state} ->
        :ok = RecordingRegistry.put(self(), {handler, ctx, handler_state})

        state = maybe_attach_layout(state, layout?)

        {expected, multi_home?} =
          if multi_home? do
            # Spokes never run layout; strip layout from fan-out opts.
            remote_opts =
              start_opts
              |> Map.put(:layout, false)
              |> Map.delete("layout")
              |> Map.delete(:rtmp_url)
              |> Map.delete("rtmp_url")
              |> Map.delete(:plan_ref)

            ctx_fields = %{
              recording_id: recording_id,
              sequence: sequence,
              preceded_by: preceded_by,
              mode: mode,
              coordinator_node: Node.self()
            }

            {ok_nodes, _errs} = RecordingCluster.broadcast_start(key, ctx_fields, remote_opts)

            expected =
              [Node.self() | ok_nodes]
              |> Enum.map(&to_string/1)
              |> Enum.uniq()

            :ok =
              Aggregator.begin_segment(%{
                recording_id: recording_id,
                tenant_id: state.tenant_id,
                session_id: state.id,
                sequence: sequence,
                preceded_by: preceded_by,
                mode: recording_mode_string(mode),
                started_at: started_at,
                expected_edges: expected
              })

            {expected, true}
          else
            {[], false}
          end

        info = %{
          recording_id: recording_id,
          sequence: sequence,
          preceded_by: preceded_by,
          mode: mode,
          started_at: started_at,
          multi_home: multi_home?,
          coordinator: true,
          coordinator_node: Node.self(),
          expected_edges: expected,
          layout: layout?,
          rtmp_url: recording_rtmp_url(opts)
        }

        new_state = %{
          state
          | recording: info,
            recording_seq: sequence
        }

        {:ok,
         Map.drop(info, [
           :started_at,
           :multi_home,
           :coordinator,
           :coordinator_node,
           :expected_edges,
           :layout,
           :rtmp_url
         ]), new_state}

      {:error, reason} ->
        {:error, reason, state}

      other ->
        {:error, {:invalid_on_start, other}, state}
    end
  end

  defp validate_recording_layout_opts(opts, state) do
    layout? = recording_layout?(opts)
    rtmp = recording_rtmp_url(opts)

    cond do
      not layout? and rtmp == nil ->
        :ok

      layout? and state.module_id != :conference ->
        {:error, :layout_requires_conference}

      is_binary(rtmp) and not valid_rtmp_url?(rtmp) ->
        {:error, :invalid_rtmp_url}

      rtmp != nil and not layout? ->
        {:error, :rtmp_requires_layout}

      true ->
        :ok
    end
  end

  defp recording_layout?(opts) do
    case Map.get(opts, :layout) || Map.get(opts, "layout") do
      true -> true
      "true" -> true
      "1" -> true
      1 -> true
      _ -> false
    end
  end

  defp recording_rtmp_url(opts) do
    case Map.get(opts, :rtmp_url) || Map.get(opts, "rtmp_url") do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp valid_rtmp_url?(url) do
    String.starts_with?(url, "rtmp://") or String.starts_with?(url, "rtmps://")
  end

  defp maybe_attach_layout(state, true) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :attach_layout_recording, 2) do
      case backend.attach_layout_recording([forwarder: state.forwarder], state.backend_state) do
        {:ok, backend_state} -> %{state | backend_state: backend_state}
        {:error, _} -> state
      end
    else
      state
    end
  end

  defp maybe_attach_layout(state, _), do: state

  defp maybe_detach_layout(state) do
    backend = state.backend
    _ = Code.ensure_loaded(backend)

    if function_exported?(backend, :detach_layout_recording, 2) do
      case backend.detach_layout_recording([forwarder: state.forwarder], state.backend_state) do
        {:ok, backend_state} -> %{state | backend_state: backend_state}
        _ -> state
      end
    else
      state
    end
  end

  defp do_remote_start_recording(%{recording: meta} = state, _ctx_fields, _opts) when is_map(meta) do
    {:error, :conflict, state}
  end

  defp do_remote_start_recording(state, ctx_fields, opts) do
    recording_id = Map.fetch!(ctx_fields, :recording_id)
    sequence = Map.fetch!(ctx_fields, :sequence)
    preceded_by = Map.get(ctx_fields, :preceded_by)
    mode = recording_mode(Map.fetch!(ctx_fields, :mode))
    coordinator_node = Map.fetch!(ctx_fields, :coordinator_node)
    started_at = System.system_time(:millisecond)

    ctx = %Ctx{
      tenant_id: state.tenant_id,
      session_id: state.id,
      recording_id: recording_id,
      sequence: sequence,
      preceded_by: preceded_by,
      mode: mode,
      edge_node: Node.self()
    }

    handler = Recording.handler()
    start_opts =
      opts
      |> Map.drop([:mode, "mode"])
      |> Map.put(:plan_ref, self())
      # Remote edges never run live layout (coordinator-only).
      |> Map.put(:layout, false)
      |> Map.delete("layout")
      |> Map.delete(:rtmp_url)
      |> Map.delete("rtmp_url")

    case handler.on_start(ctx, start_opts) do
      {:ok, handler_state} ->
        :ok = RecordingRegistry.put(self(), {handler, ctx, handler_state})

        info = %{
          recording_id: recording_id,
          sequence: sequence,
          preceded_by: preceded_by,
          mode: mode,
          started_at: started_at,
          multi_home: true,
          coordinator: false,
          coordinator_node: coordinator_node
        }

        # Keep local sequence at least as high as shared segment sequence.
        new_seq = max(state.recording_seq, sequence)

        new_state = %{state | recording: info, recording_seq: new_seq}
        {:ok, Map.drop(info, [:started_at, :multi_home, :coordinator, :coordinator_node]), new_state}

      {:error, reason} ->
        {:error, reason, state}

      other ->
        {:error, {:invalid_on_start, other}, state}
    end
  rescue
    e -> {:error, Exception.message(e), state}
  catch
    kind, reason -> {:error, Exception.format_exit({kind, reason}), state}
  end

  defp do_stop_recording(%{recording: nil} = state), do: {:error, :not_found, state}

  defp do_stop_recording(%{recording: %{multi_home: true, coordinator: false} = rec} = state) do
    # Spoke edge: Control should not stop here; treat as remote finalize to coordinator.
    coordinator = Map.get(rec, :coordinator_node, Node.self())

    case do_remote_stop_recording(state, Map.fetch!(rec, :recording_id), coordinator) do
      {:ok, new_state} ->
        {:ok, %{recording_id: Map.fetch!(rec, :recording_id), status: "finalizing"}, new_state}

      {:error, reason, new_state} ->
        {:error, reason, new_state}
    end
  end

  defp do_stop_recording(%{recording: %{multi_home: true, coordinator: true} = rec} = state) do
    recording_id = Map.fetch!(rec, :recording_id)
    key = {state.tenant_id, state.id}
    state = ensure_late_cohost_recording(state, rec)
    rec = state.recording
    {event, report} = finalize_local_report(state, rec)

    :ok =
      Aggregator.report_edge(recording_id, Map.put(report, :edge_node, to_string(Node.self())))

    :ok = RecordingCluster.broadcast_stop(key, recording_id, Node.self())
    :ok = Aggregator.await_or_flush(recording_id, @recording_aggregate_timeout_ms)

    # Aggregator already emitted; event unused for multi-home coordinator path.
    _ = event

    info = %{recording_id: recording_id, status: "finalizing"}

    new_state =
      %{
        state
        | recording: nil,
          last_recording_id: recording_id
      }
      |> maybe_detach_layout()

    {:ok, info, new_state}
  end

  defp do_stop_recording(%{recording: rec} = state) do
    recording_id = Map.fetch!(rec, :recording_id)
    ended_at = System.system_time(:millisecond)
    started_at = Map.get(rec, :started_at, ended_at)

    {event, payload_extra} =
      case RecordingRegistry.take(self()) do
        {mod, ctx, handler_state} ->
          result =
            try do
              mod.on_stop(ctx, handler_state)
            rescue
              e -> {:error, Exception.message(e)}
            catch
              kind, reason -> {:error, Exception.format_exit({kind, reason})}
            end

          case result do
            {:ok, manifest} when is_map(manifest) ->
              {"recording.completed",
               recording_webhook_from_manifest(state, rec, started_at, ended_at, manifest)}

            {:ok, _} ->
              {"recording.completed",
               recording_webhook_from_manifest(state, rec, started_at, ended_at, %{})}

            {:error, reason} ->
              {"recording.failed",
               recording_webhook_base(state, rec, started_at, ended_at)
               |> Map.put("error", recording_error_string(reason))
               |> Map.put("artifacts", [])
               |> Map.put("counters", %{})}

            other ->
              {"recording.failed",
               recording_webhook_base(state, rec, started_at, ended_at)
               |> Map.put("error", recording_error_string({:invalid_on_stop, other}))
               |> Map.put("artifacts", [])
               |> Map.put("counters", %{})}
          end

        nil ->
          {"recording.completed",
           recording_webhook_from_manifest(state, rec, started_at, ended_at, %{})}
      end

    Xylon.Control.Webhooks.emit(event, payload_extra)

    info = %{recording_id: recording_id, status: "finalizing"}

    new_state =
      %{
        state
        | recording: nil,
          last_recording_id: recording_id
      }
      |> maybe_detach_layout()

    {:ok, info, new_state}
  end

  defp do_remote_stop_recording(%{recording: nil} = state, _recording_id, _coordinator_node) do
    {:error, :not_found, state}
  end

  defp do_remote_stop_recording(%{recording: rec} = state, recording_id, coordinator_node) do
    if Map.fetch!(rec, :recording_id) != recording_id do
      {:error, :mismatch, state}
    else
      {_event, report} = finalize_local_report(state, rec)

      _ =
        RecordingCluster.report_to_coordinator(
          coordinator_node,
          recording_id,
          Map.put(report, :edge_node, to_string(Node.self()))
        )

      new_state = %{state | recording: nil, last_recording_id: recording_id}
      {:ok, new_state}
    end
  end

  defp finalize_local_report(state, rec) do
    ended_at = System.system_time(:millisecond)
    started_at = Map.get(rec, :started_at, ended_at)

    case RecordingRegistry.take_with_local(self()) do
      {{mod, ctx, handler_state}, had_local} ->
        result =
          try do
            mod.on_stop(ctx, handler_state)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, Exception.format_exit({kind, reason})}
          end

        case result do
          {:ok, manifest} when is_map(manifest) ->
            payload = recording_webhook_from_manifest(state, rec, started_at, ended_at, manifest)
            artifacts = Map.get(payload, "artifacts", [])

            {"recording.completed",
             %{
               artifacts: artifacts,
               counters: Map.get(payload, "counters", %{}),
               had_local_publishers: had_local or artifacts != []
             }}

          {:ok, _} ->
            {"recording.completed",
             %{artifacts: [], counters: %{}, had_local_publishers: had_local}}

          {:error, reason} ->
            {"recording.failed",
             %{
               artifacts: [],
               counters: %{},
               error: recording_error_string(reason),
               had_local_publishers: had_local
             }}

          other ->
            {"recording.failed",
             %{
               artifacts: [],
               counters: %{},
               error: recording_error_string({:invalid_on_stop, other}),
               had_local_publishers: had_local
             }}
        end

      nil ->
        {"recording.completed",
         %{artifacts: [], counters: %{}, had_local_publishers: false}}
    end
  end

  defp maybe_include_cohost_recording_state(%{recording: rec} = state, peer_node)
       when is_map(rec) and is_atom(peer_node) do
    if peer_node == Node.self() do
      state
    else
      do_include_cohost_recording(state, rec, peer_node)
    end
  end

  defp maybe_include_cohost_recording_state(state, _peer_node), do: state

  defp do_include_cohost_recording(
         state,
         %{multi_home: true, coordinator: true} = rec,
         peer_node
       ) do
    edge_s = to_string(peer_node)
    expected = Map.get(rec, :expected_edges, [])

    if edge_s in expected do
      state
    else
      start_peer_and_expect(state, rec, peer_node, edge_s, expected)
    end
  end

  defp do_include_cohost_recording(state, rec, peer_node) do
    # Recording began single-node; promote to multi-home coordinator for the late cohost.
    edge_self = to_string(Node.self())
    edge_peer = to_string(peer_node)
    recording_id = Map.fetch!(rec, :recording_id)

    :ok =
      Aggregator.begin_segment(%{
        recording_id: recording_id,
        tenant_id: state.tenant_id,
        session_id: state.id,
        sequence: Map.fetch!(rec, :sequence),
        preceded_by: Map.get(rec, :preceded_by),
        mode: recording_mode_string(Map.get(rec, :mode)),
        started_at: Map.get(rec, :started_at, System.system_time(:millisecond)),
        expected_edges: [edge_self]
      })

    rec = %{
      rec
      | multi_home: true,
        coordinator: true,
        coordinator_node: Node.self(),
        expected_edges: [edge_self]
    }

    state = %{state | recording: rec}
    start_peer_and_expect(state, rec, peer_node, edge_peer, [edge_self])
  end

  defp start_peer_and_expect(state, rec, peer_node, edge_s, expected) do
    ctx_fields = %{
      recording_id: Map.fetch!(rec, :recording_id),
      sequence: Map.fetch!(rec, :sequence),
      preceded_by: Map.get(rec, :preceded_by),
      mode: Map.get(rec, :mode),
      coordinator_node: Node.self()
    }

    case RecordingCluster.start_on_peer(
           peer_node,
           state.tenant_id,
           state.id,
           ctx_fields,
           %{}
         ) do
      :ok ->
        _ = Aggregator.add_expected_edges(Map.fetch!(rec, :recording_id), [edge_s])

        %{
          state
          | recording: %{rec | expected_edges: Enum.uniq([edge_s | expected])}
        }

      {:error, _} ->
        state
    end
  end

  defp ensure_late_cohost_recording(state, _rec) do
    case state.recording do
      rec when is_map(rec) ->
        key = {state.tenant_id, state.id}

        Enum.reduce(RecordingCluster.peer_hubs(key), state, fn peer, st ->
          maybe_include_cohost_recording_state(st, peer)
        end)

      _ ->
        state
    end
  end

  defp recording_webhook_base(state, rec, started_at, ended_at) do
    %{
      "tenant_id" => to_string(state.tenant_id),
      "session_id" => to_string(state.id),
      "recording_id" => Map.fetch!(rec, :recording_id),
      "sequence" => Map.get(rec, :sequence),
      "preceded_by" => Map.get(rec, :preceded_by),
      "mode" => recording_mode_string(Map.get(rec, :mode)),
      "started_at" => started_at,
      "ended_at" => ended_at
    }
  end

  defp recording_webhook_from_manifest(state, rec, started_at, ended_at, manifest) do
    artifacts =
      (Map.get(manifest, :artifacts) || Map.get(manifest, "artifacts") || [])
      |> List.wrap()
      |> Enum.map(&normalize_recording_artifact/1)

    counters =
      case Map.get(manifest, :counters) || Map.get(manifest, "counters") do
        c when is_map(c) -> stringify_keys(c)
        _ -> %{}
      end

    dropped = Map.get(manifest, :dropped_backpressure) || Map.get(manifest, "dropped_backpressure")

    counters =
      if is_integer(dropped) do
        Map.put(counters, "dropped_backpressure", dropped)
      else
        counters
      end

    recording_webhook_base(state, rec, started_at, ended_at)
    |> Map.put("artifacts", artifacts)
    |> Map.put("counters", counters)
  end

  defp normalize_recording_artifact(art) when is_map(art) do
    path =
      Map.get(art, :path_or_key) || Map.get(art, "path_or_key") || Map.get(art, :path) ||
        Map.get(art, "path")

    %{
      "kind" => stringify_artifact_field(Map.get(art, :kind) || Map.get(art, "kind")),
      "publisher_id" => stringify_artifact_field(Map.get(art, :publisher_id) || Map.get(art, "publisher_id")),
      "mid" => stringify_artifact_field(Map.get(art, :mid) || Map.get(art, "mid")),
      "codec" => stringify_artifact_field(Map.get(art, :codec) || Map.get(art, "codec")),
      "path_or_key" =>
        case path do
          p when is_binary(p) and p != "" -> Path.expand(p)
          _ -> nil
        end,
      "bytes" => Map.get(art, :bytes) || Map.get(art, "bytes") || 0,
      "via" => Map.get(art, :via) || Map.get(art, "via"),
      "edge_node" =>
        case Map.get(art, :edge_node) || Map.get(art, "edge_node") do
          nil -> "local"
          n -> to_string(n)
        end
    }
  end

  defp normalize_recording_artifact(_), do: %{}

  defp stringify_artifact_field(nil), do: nil
  defp stringify_artifact_field(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_artifact_field(v), do: to_string(v)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp recording_mode_string(:tracks_and_mix), do: "tracks_and_mix"
  defp recording_mode_string("tracks_and_mix"), do: "tracks_and_mix"
  defp recording_mode_string(_), do: "tracks"

  defp recording_error_string(reason) when is_binary(reason), do: reason
  defp recording_error_string(reason), do: inspect(reason)

  defp maybe_flush_recording(%{recording: nil} = state), do: state

  defp maybe_flush_recording(%{recording: %{multi_home: true, coordinator: true} = rec} = state) do
    recording_id = Map.fetch!(rec, :recording_id)
    key = {state.tenant_id, state.id}
    state = ensure_late_cohost_recording(state, rec)
    rec = state.recording
    {_event, report} = finalize_local_report(state, rec)

    _ =
      Aggregator.report_edge(recording_id, Map.put(report, :edge_node, to_string(Node.self())))

    _ = RecordingCluster.broadcast_stop(key, recording_id, Node.self())
    _ = Aggregator.force_flush(recording_id)

    %{state | recording: nil, last_recording_id: recording_id}
    |> maybe_detach_layout()
  end

  defp maybe_flush_recording(%{recording: %{multi_home: true, coordinator: false} = rec} = state) do
    coordinator = Map.get(rec, :coordinator_node, Node.self())

    case do_remote_stop_recording(state, Map.fetch!(rec, :recording_id), coordinator) do
      {:ok, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  defp maybe_flush_recording(state) do
    case do_stop_recording(state) do
      {:ok, _info, new_state} -> new_state
    end
  end

  defp recording_mode(:tracks_and_mix), do: :tracks_and_mix
  defp recording_mode("tracks_and_mix"), do: :tracks_and_mix
  defp recording_mode(:tracks), do: :tracks
  defp recording_mode("tracks"), do: :tracks
  defp recording_mode(_), do: :tracks

  defp resolve_recording_mode(opts, backend_state) when is_map(opts) do
    case Map.fetch(opts, :mode) do
      {:ok, mode} ->
        recording_mode(mode)

      :error ->
        case Map.fetch(opts, "mode") do
          {:ok, mode} ->
            recording_mode(mode)

          :error ->
            auto_recording_mode(backend_state)
        end
    end
  end

  defp auto_recording_mode(%{audio: :mcu}), do: :tracks_and_mix
  defp auto_recording_mode(_), do: :tracks

  defp mint_recording_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
