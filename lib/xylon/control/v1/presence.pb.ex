defmodule Xylon.Control.V1.GetPresenceRequest do
  @moduledoc """
  Generated Control API message for presence read requests.

  ## What problem this solves

  Wire schema for `PresenceService.Get` RPC (out-of-band control, not STUN/TURN).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :tenant_id, 1, type: :string, json_name: "tenantId"
  field :session_id, 2, type: :string, json_name: "sessionId"
end

defmodule Xylon.Control.V1.Participant do
  @moduledoc """
  Generated Control API message for one room participant in presence responses.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :role, 1, type: :string
  field :joined_at, 2, type: :int64, json_name: "joinedAt"
  field :meta_json, 3, type: :string, json_name: "metaJson"
end

defmodule Xylon.Control.V1.GetPresenceResponse.ParticipantsEntry do
  @moduledoc """
  Generated protobuf map entry for participant id to `Participant`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, map: true, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Xylon.Control.V1.Participant
end

defmodule Xylon.Control.V1.GetPresenceResponse do
  @moduledoc """
  Generated Control API message for presence read responses.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :participants, 1,
    repeated: true,
    type: Xylon.Control.V1.GetPresenceResponse.ParticipantsEntry,
    map: true
end

defmodule Xylon.Control.V1.PresenceService.Service do
  @moduledoc """
  Generated gRPC service definition for Control presence API.

  ## What problem this solves

  Registers `PresenceService.Get` RPC (out-of-band control, not STUN/TURN).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Service,
    name: "xylon.control.v1.PresenceService",
    protoc_gen_elixir_version: "0.14.0"

  rpc :Get, Xylon.Control.V1.GetPresenceRequest, Xylon.Control.V1.GetPresenceResponse
end

defmodule Xylon.Control.V1.PresenceService.Stub do
  @moduledoc """
  Generated gRPC client stub for `PresenceService`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Stub, service: Xylon.Control.V1.PresenceService.Service
end
