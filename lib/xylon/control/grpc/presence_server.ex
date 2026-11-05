defmodule Xylon.Control.Grpc.PresenceServer do
  @moduledoc """
  gRPC `PresenceService.Get` handler.

  ## What problem this solves

  Monitoring and orchestration services need a room roster without opening a
  Control WebSocket. Authenticates Bearer HMAC/JWT and returns
  `Presence.list/2` as protobuf participants.

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Server, service: Xylon.Control.V1.PresenceService.Service

  alias Xylon.Control.Grpc.Auth
  alias Xylon.Control.Presence
  alias Xylon.Control.V1.{GetPresenceRequest, GetPresenceResponse, Participant}

  @doc "RPC Get -- presence snapshot for a room."
  @spec get(GetPresenceRequest.t(), GRPC.Server.Stream.t()) :: GetPresenceResponse.t()
  def get(%GetPresenceRequest{} = req, stream) do
    case Auth.authenticate(stream, req.tenant_id, req.session_id) do
      {:ok, ctx} ->
        participants =
          Presence.list(ctx.tenant_id, ctx.session_id)
          |> Enum.map(fn {id, meta} -> {to_string(id), to_participant(meta)} end)
          |> Map.new()

        %GetPresenceResponse{participants: participants}

      {:error, reason} ->
        raise Auth.rpc_error(reason)
    end
  end

  defp to_participant(meta) when is_map(meta) do
    role = Map.get(meta, "role") || Map.get(meta, :role)
    joined_at = Map.get(meta, "joined_at") || Map.get(meta, :joined_at) || 0
    nested = Map.get(meta, "meta") || Map.get(meta, :meta) || %{}

    %Participant{
      role: role_string(role),
      joined_at: joined_at_int(joined_at),
      meta_json: Jason.encode!(stringify_keys(nested))
    }
  end

  defp role_string(nil), do: ""
  defp role_string(role) when is_atom(role), do: Atom.to_string(role)
  defp role_string(role) when is_binary(role), do: role
  defp role_string(other), do: to_string(other)

  defp joined_at_int(n) when is_integer(n), do: n
  defp joined_at_int(_), do: 0

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
