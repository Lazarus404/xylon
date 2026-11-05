defmodule Xylon.Control.Grpc.InjectServer do
  @moduledoc """
  gRPC `InjectService.Publish` handler.

  ## What problem this solves

  Service-to-service inject callers need a typed RPC instead of REST. This server
  verifies Bearer HMAC/JWT (lab `x-tenant-id` is rejected), maps the protobuf
  request to `Inject.publish/4`, and raises gRPC errors on failure. ACL, quota,
  and moderation stay in Inject (not duplicated here).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Server, service: Xylon.Control.V1.InjectService.Service

  alias Xylon.Control.Grpc.Auth
  alias Xylon.Control.Inject
  alias Xylon.Control.V1.{PublishRequest, PublishResponse}

  @doc "RPC Publish -- maps inject errors to gRPC status codes."
  @spec publish(PublishRequest.t(), GRPC.Server.Stream.t()) :: PublishResponse.t()
  def publish(%PublishRequest{} = req, stream) do
    with {:ok, ctx} <- Auth.authenticate(stream, req.tenant_id, req.session_id),
         {:ok, payload} <- payload_bin(req.payload),
         {:ok, dest} <- parse_dest(req),
         label <- Auth.nonempty(req.label),
         :ok <- Inject.publish(ctx, payload, dest, label: label) do
      %PublishResponse{}
    else
      {:error, reason} -> raise Auth.rpc_error(reason)
    end
  end

  defp payload_bin(payload) when is_binary(payload) and payload != "", do: {:ok, payload}
  defp payload_bin(_), do: {:error, :invalid_argument}

  defp parse_dest(%PublishRequest{dest_ids: ids}) when is_list(ids) and ids != [] do
    cleaned = Enum.filter(ids, &(is_binary(&1) and &1 != ""))

    if cleaned == [] do
      {:error, :empty_dest}
    else
      {:ok, cleaned}
    end
  end

  defp parse_dest(%PublishRequest{dest: dest}) when dest in ["all", "except"], do: {:ok, dest}
  defp parse_dest(%PublishRequest{dest: ""}), do: {:error, :invalid_argument}
  defp parse_dest(%PublishRequest{dest: dest}) when is_binary(dest), do: {:ok, dest}
  defp parse_dest(_), do: {:error, :invalid_argument}
end
