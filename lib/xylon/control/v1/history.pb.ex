defmodule Xylon.Control.V1.GetHistoryRequest do
  @moduledoc """
  Generated Control API message for history read requests.

  ## What problem this solves

  Wire schema for `HistoryService.Get` RPC (out-of-band control, not STUN/TURN).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :tenant_id, 1, type: :string, json_name: "tenantId"
  field :session_id, 2, type: :string, json_name: "sessionId"
  field :label, 3, type: :string
end

defmodule Xylon.Control.V1.HistoryMessage do
  @moduledoc """
  Generated Control API message for one history row.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :ts, 1, type: :int64
  field :from, 2, type: :string
  field :label, 3, type: :string
  field :payload, 4, type: :bytes
end

defmodule Xylon.Control.V1.GetHistoryResponse do
  @moduledoc """
  Generated Control API message for history read responses.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use Protobuf, protoc_gen_elixir_version: "0.14.0", syntax: :proto3

  field :messages, 1, repeated: true, type: Xylon.Control.V1.HistoryMessage
end

defmodule Xylon.Control.V1.HistoryService.Service do
  @moduledoc """
  Generated gRPC service definition for Control history API.

  ## What problem this solves

  Registers `HistoryService.Get` RPC (out-of-band control, not STUN/TURN).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Service,
    name: "xylon.control.v1.HistoryService",
    protoc_gen_elixir_version: "0.14.0"

  rpc :Get, Xylon.Control.V1.GetHistoryRequest, Xylon.Control.V1.GetHistoryResponse
end

defmodule Xylon.Control.V1.HistoryService.Stub do
  @moduledoc """
  Generated gRPC client stub for `HistoryService`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Stub, service: Xylon.Control.V1.HistoryService.Service
end
