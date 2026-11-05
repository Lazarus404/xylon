defmodule Xylon.Recording.Handler do
  @moduledoc """
  Behaviour for room recording taps (stems, mix, finalize).

  ## What problem this solves

  Control can start and stop a recording on a Session, but writing archives must
  stay off the live SFU hot path. Xylon defines this behaviour and invokes the
  configured module from application env. A no-op Null handler ships by default;
  the reference writer is [xylon_record](https://github.com/Lazarus404/xylon_record).

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane + media tap contract. Stem format
  for real handlers is Janus `.mjr` (MJR00002); see product recording design.
  """

  alias Xylon.Recording.Ctx

  @typedoc "Opaque per-recording state returned by `on_start/2` and threaded through RTP callbacks."
  @type state :: term()

  @typedoc """
  Publisher or mix packet metadata for RTP callbacks.

  ## Fields

  - `:publisher_id` - Participant id (or mix publisher id for mix taps).
  - `:mid` - SDP mid when known.
  - `:kind` - `:audio`, `:video`, or `:unknown`.
  - `:ssrc` - Inbound RTP SSRC.
  - `:layer` / `:rid` - Simulcast/SVC hints when known (Phase 5+).
  - `:via` - Optional path tag (e.g. `:trunk`).
  - `:edge_node` - BEAM node that saw the packet.
  """
  @type meta :: %{
          optional(:publisher_id) => term(),
          optional(:mid) => binary() | nil,
          optional(:kind) => :audio | :video | :unknown,
          optional(:ssrc) => non_neg_integer(),
          optional(:layer) => term(),
          optional(:rid) => binary() | nil,
          optional(:via) => term(),
          optional(:edge_node) => node()
        }

  @doc "Called once when Control starts a recording on this edge."
  @callback on_start(Ctx.t(), map()) :: {:ok, state()} | {:error, term()}

  @doc "Called when Control stops recording or the Session ends."
  @callback on_stop(Ctx.t(), state()) :: {:ok, term()} | {:error, term()}

  @doc """
  Publisher plaintext RTP while recording is active.

  Must enqueue and return quickly; never block on disk or network I/O.
  """
  @callback on_publisher_rtp(Ctx.t(), state(), meta(), term()) :: {:ok, state()}

  @doc """
  Mixed audio RTP when mode includes mix and the room mixes.

  Must enqueue and return quickly.
  """
  @callback on_mix_rtp(Ctx.t(), state(), meta(), term()) :: {:ok, state()}
end
