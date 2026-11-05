defmodule Xylon.Backend do
  @moduledoc """
  Pluggable media policy for a session (echo, SFU, recording, ...).

  ## What problem this solves

  Once [XGW](https://github.com/Lazarus404/xgw) decrypts incoming packets, the
  server must decide what to do with them: send them back to the sender (echo),
  forward to other participants (SFU), mix, record, etc. A **backend**
  implements that policy. It sees only plaintext RTP/RTCP and datachannel bytes;
  DTLS keys and SRTP never leave XGW.

  Register backends with `Xylon.attach/1`; reference them by catalogue `id/0`.

  ## Session vs Forwarder (dual init)

  `Xylon.Session` and `Xylon.Forwarder` each call `init/2` and keep a separate
  opaque `backend_state` map. Session owns control/lifecycle callbacks; Forwarder
  owns the media hot path. Those maps are **not** synchronized automatically.

  | Process | Typical callbacks |
  | --- | --- |
  | Session | `init/2`, `participant_joined/2`, `participant_left/2`, optional subscribe /
    publish / `media_ready/4`, DC open/close/SCTP, `terminate/2` |
  | Forwarder | `init/2` again, then `handle_rtp/3`, `handle_rtcp/3`, `handle_datachannel/4` |

  Mutable fields both paths must see (membership, label maps, TWCC ext ids, and
  similar) belong in an **external store keyed by the Session pid** (passed as
  `:session_pid` in init opts), for example a Plan or Runtime ETS table in the
  backend package -- not only in `backend_state`. Room opts that are identical
  after both inits may stay in the maps.

  ## RFCs and related specs

  Backends operate on media already decoded per RTP
  ([RFC 3550](https://www.rfc-editor.org/rfc/rfc3550)) and SCTP datachannels
  negotiated in SDP ([RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) via
  [XSDP](https://github.com/Lazarus404/xsdp)).
  """

  @type state :: term()
  @type participant :: Xylon.Participant.t()
  @type forward_spec :: {participant(), term()}
  @type dc_forward_spec :: {participant(), reference(), binary()}

  @doc """
  Called once when a Session starts. Return opaque backend state or an error.
  """
  @callback init(session :: Xylon.Session.t(), opts :: keyword()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Called after a participant's Peer is up and the Forwarder plan is installed.
  """
  @callback participant_joined(participant(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Called when a participant leaves or their Peer closes. Always returns `{:ok, state}`.
  """
  @callback participant_left(participant(), state()) :: {:ok, state()}

  @doc """
  Handle one inbound RTP packet. Return `{:forward, specs, state}` to send
  rewritten packets to other participants via XGW.
  """
  @callback handle_rtp(participant(), term(), state()) ::
              {:ok, state()}
              | {:forward, [forward_spec()], state()}
              | {:error, term()}

  @doc """
  Handle one inbound RTCP packet. Echo backends typically ignore RTCP.
  """
  @callback handle_rtcp(participant(), term(), state()) ::
              {:ok, state()} | {:error, term()}

  @doc """
  Handle one inbound datachannel message. Return `{:forward_dc, specs, state}` to
  send payloads to other participants.
  """
  @callback handle_datachannel(participant(), reference(), binary(), state()) ::
              {:ok, state()}
              | {:forward_dc, [dc_forward_spec()], state()}
              | {:error, term()}

  @doc """
  Optional: datachannel opened (label and SCTP stream id in `open` map).
  """
  @callback handle_datachannel_open(
              participant(),
              %{ref: reference(), label: binary(), id: term()},
              state()
            ) :: {:ok, state()} | {:forward_dc, [dc_forward_spec()], state()}

  @doc "Optional: datachannel closed for `channel_ref`."
  @callback handle_datachannel_closed(participant(), reference(), state()) :: {:ok, state()}

  @doc "Optional: SCTP association dropped for the participant."
  @callback handle_sctp_disconnected(participant(), state()) :: {:ok, state()}

  @doc """
  Optional: server-originated datachannel inject from Session control plane.
  """
  @callback publish_datachannel(
              payload :: binary(),
              dest :: :all | [term()],
              opts :: keyword(),
              state()
            ) ::
              {:ok, state()}
              | {:forward_dc, [dc_forward_spec()], state()}
              | {:error, term()}

  @doc "Called when the Session stops and all participants are gone."
  @callback terminate(reason :: term(), state()) :: :ok

  @doc """
  Optional: Forwarder plan map after join
  (`%{mode: :echo | :sfu | :datachannel, participant: ...}`).

  When omitted, Session falls back to `Forwarder.install_echo/2`. When exported,
  must return `{:ok, plan_map, state}`; any other return fails join/attach with
  `{:error, {:invalid_forward_plan, term}}` (no silent echo install).
  """
  @callback forward_plan(participant(), state()) :: {:ok, map(), state()}

  @doc """
  Optional: called after join + Forwarder plan install with the remote offer SDP.

  `ctx` includes `%{forwarder: pid()}`. Used by SFU backends to publish tracks
  and mesh-subscribe from offer SSRCs.
  """
  @callback media_ready(
              participant(),
              offer_sdp :: binary(),
              ctx :: map(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: subscribe `subscriber_id` to `publisher_id`'s track at SDP `mid`.

  `opts` may include `:forwarder`. Used by conference SFU selective subscribe.
  """
  @callback subscribe(
              subscriber_id :: term(),
              publisher_id :: term(),
              mid :: binary(),
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: subscribe `subscriber_id` to every published mid on `publisher_id`.
  """
  @callback subscribe_all(
              subscriber_id :: term(),
              publisher_id :: term(),
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: remove a subscribe route for `mid`.
  """
  @callback unsubscribe(
              subscriber_id :: term(),
              publisher_id :: term(),
              mid :: binary(),
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: stop publishing selected mids without removing the participant.

  `mids` is `:all` or a nonempty list of SDP mid strings.
  """
  @callback unpublish(
              participant_id :: term(),
              mids :: :all | [binary()],
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: switch an existing subscription to another publisher for `mid`.
  """
  @callback switch(
              subscriber_id :: term(),
              to_publisher_id :: term(),
              mid :: binary(),
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: change simulcast / SVC layer opts for a subscription.

  `opts` may include `:substream`, `:rid`, `:temporal`, `:spatial_layer`,
  `:temporal_layer`, and `:forwarder`.
  """
  @callback set_substream(
              subscriber_id :: term(),
              publisher_id :: term(),
              mid :: binary(),
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: pause or resume outbound routes for published mids (`:mute` / `:unmute`).

  `mids` is a list of SDP mids, or `nil` for all published mids on the publisher.
  """
  @callback moderate_av(
              publisher_id :: term(),
              action :: :mute | :unmute,
              mids :: [binary()] | nil,
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @doc """
  Optional: replace all subscribe routes for `subscriber_id` from `streams`.

  Each entry is `%{publisher_id: id, mid: mid}` or `%{publisher_id: id}` (all mids).
  """
  @callback update_subscriptions(
              subscriber_id :: term(),
              streams :: [map()],
              opts :: keyword(),
              state()
            ) :: {:ok, state()} | {:error, term()}

  @optional_callbacks handle_datachannel_open: 3,
                      handle_datachannel_closed: 3,
                      handle_sctp_disconnected: 2,
                      publish_datachannel: 4,
                      forward_plan: 2,
                      media_ready: 4,
                      subscribe: 5,
                      subscribe_all: 4,
                      unsubscribe: 5,
                      unpublish: 4,
                      switch: 5,
                      set_substream: 5,
                      moderate_av: 5,
                      update_subscriptions: 4
end
