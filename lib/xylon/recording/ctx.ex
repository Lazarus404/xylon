defmodule Xylon.Recording.Ctx do
  @moduledoc """
  Immutable context passed to every recording handler callback.

  ## What problem this solves

  Start/stop and RTP hooks need the same tenant/session/recording identity so a
  writer can name files and attribute webhooks later. This struct is built once
  on start and stored in the recording registry for the hot path.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane recording context.

  ## Fields

  - `:tenant_id` - Tenant that owns the room.
  - `:session_id` - Room / session id.
  - `:recording_id` - Unique id for this capture segment.
  - `:sequence` - Rising segment index within the session (splice ordering).
  - `:preceded_by` - Prior `recording_id` when this segment continues a stop/start cycle; nil on first.
  - `:mode` - `:tracks` or `:tracks_and_mix`.
  - `:edge_node` - BEAM node that owns this edge's capture.
  """

  @typedoc "Recording context for handler callbacks."
  @type t :: %__MODULE__{
          tenant_id: term(),
          session_id: term(),
          recording_id: binary(),
          sequence: pos_integer(),
          preceded_by: binary() | nil,
          mode: :tracks | :tracks_and_mix,
          edge_node: node()
        }

  @enforce_keys [:tenant_id, :session_id, :recording_id, :sequence, :mode, :edge_node]
  defstruct tenant_id: nil,
            session_id: nil,
            recording_id: nil,
            sequence: 1,
            preceded_by: nil,
            mode: :tracks,
            edge_node: nil
end
