defmodule Xylon.Control.Grpc.Endpoint do
  @moduledoc """
  gRPC endpoint wiring for Control host APIs.

  ## What problem this solves

  Backend services prefer gRPC over REST for inject, presence, and history.
  Endpoint registers `InjectServer`, `PresenceServer`, and `HistoryServer`
  when `config :xylon, control: [enabled: true, grpc_port: N]`.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Endpoint

  run Xylon.Control.Grpc.InjectServer
  run Xylon.Control.Grpc.PresenceServer
  run Xylon.Control.Grpc.HistoryServer
end
