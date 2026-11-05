defmodule Xylon.Control.Context do
  @moduledoc """
  Authenticated control-plane identity after tenant auth succeeds.

  ## What problem this solves

  Control routes (HTTP inject, WebSocket join, gRPC Publish) must know which
  tenant, session, and participant is acting before ACL, quota, or moderation
  run. `Context` is that stable struct: auth modules mint or verify it; Inject,
  Router, and gRPC servers pass it downstream. `capabilities` are opaque to
  Control; backends may interpret them via `:authorize`.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  @typedoc """
  Authenticated tenant/session/participant plus opaque capabilities.

  ## Fields

  - `:tenant_id` - From lab header, HMAC payload, or JWT claim.
  - `:session_id` - Room id bound to the request path or token.
  - `:participant_id` - Acting participant (inject sender or join identity).
  - `:capabilities` - Opaque list or map (e.g. `"inject"`, `"moderate"`).
  """
  @type t :: %__MODULE__{
          tenant_id: binary(),
          session_id: binary(),
          participant_id: binary(),
          capabilities: list() | map()
        }

  @enforce_keys [:tenant_id, :session_id, :participant_id]
  defstruct tenant_id: nil,
            session_id: nil,
            participant_id: nil,
            capabilities: []
end
