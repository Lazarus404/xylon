defmodule Xylon.Control.V1.PublishRequest do
  @moduledoc """
  Generated Control API message for inject publish requests.

  ## What problem this solves

  Wire schema for `InjectService.Publish` RPC payloads (out-of-band control, not
  STUN/TURN media).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :tenant_id, 1, type: :string, json_name: "tenantId"
  field :session_id, 2, type: :string, json_name: "sessionId"
  field :payload, 3, type: :bytes
  field :dest, 4, type: :string
  field :dest_ids, 5, repeated: true, type: :string, json_name: "destIds"
  field :label, 6, type: :string
end

defmodule Xylon.Control.V1.PublishResponse do
  @moduledoc """
  Generated Control API message for inject publish responses.

  ## What problem this solves

  Empty success envelope for `InjectService.Publish`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3
end

defmodule Xylon.Control.V1.InjectService.Service do
  @moduledoc """
  Generated gRPC service definition for Control inject API.

  ## What problem this solves

  Registers `InjectService.Publish` RPC (out-of-band control, not STUN/TURN).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Service,
    name: "xylon.control.v1.InjectService",
    protoc_gen_elixir_version: "0.14.0"

  rpc :Publish, Xylon.Control.V1.PublishRequest, Xylon.Control.V1.PublishResponse
end

defmodule Xylon.Control.V1.InjectService.Stub do
  @moduledoc """
  Generated gRPC client stub for `InjectService`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Stub, service: Xylon.Control.V1.InjectService.Service
end
