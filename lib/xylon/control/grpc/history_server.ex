defmodule Xylon.Control.Grpc.HistoryServer do
  @moduledoc """
  gRPC `HistoryService.Get` handler.

  ## What problem this solves

  Catch-up clients and bots need recent datachannel history over gRPC. Verifies
  Bearer HMAC/JWT and returns the in-memory ring from `History.list/3` for the
  requested label (default `chat`).

  ## RFCs

  No STUN/TURN/SIP RFC; gRPC/protobuf out-of-band control-plane API.
  """
  use GRPC.Server, service: Xylon.Control.V1.HistoryService.Service

  alias Xylon.Control.Grpc.Auth
  alias Xylon.Control.History
  alias Xylon.Control.V1.{GetHistoryRequest, GetHistoryResponse, HistoryMessage}

  @doc "RPC Get -- short history ring for a label (default chat)."
  @spec get(GetHistoryRequest.t(), GRPC.Server.Stream.t()) :: GetHistoryResponse.t()
  def get(%GetHistoryRequest{} = req, stream) do
    case Auth.authenticate(stream, req.tenant_id, req.session_id) do
      {:ok, ctx} ->
        label = if req.label == "", do: "chat", else: req.label

        messages =
          History.list(ctx.tenant_id, ctx.session_id, label)
          |> Enum.map(&to_message/1)

        %GetHistoryResponse{messages: messages}

      {:error, reason} ->
        raise Auth.rpc_error(reason)
    end
  end

  defp to_message(row) when is_map(row) do
    %HistoryMessage{
      ts: row_int(row, "ts"),
      from: row_string(row, "from"),
      label: row_string(row, "label"),
      payload: row_payload(row)
    }
  end

  defp row_int(row, key) do
    case Map.get(row, key) || Map.get(row, String.to_atom(key)) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp row_string(row, key) do
    case Map.get(row, key) || Map.get(row, String.to_atom(key)) do
      s when is_binary(s) -> s
      nil -> ""
      a when is_atom(a) -> Atom.to_string(a)
      other -> to_string(other)
    end
  end

  defp row_payload(row) do
    case Map.get(row, "payload") || Map.get(row, :payload) do
      p when is_binary(p) -> p
      _ -> ""
    end
  end
end
