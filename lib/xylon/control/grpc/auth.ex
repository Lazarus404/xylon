defmodule Xylon.Control.Grpc.Auth do
  @moduledoc """
  Bearer auth and RPC error mapping for Control gRPC servers.

  ## What problem this solves

  gRPC metadata carries `authorization: Bearer ...` instead of Plug headers.
  This module extracts the token, delegates to `Auth.authenticate_bearer/2`,
  and maps Control error atoms to `GRPC.RPCError` status codes.

  ## Internal

  Shared by Inject, Presence, and History gRPC servers.

  ## RFCs

  - [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519) -- JWT (when auth mode is `:jwt`)
  - gRPC status codes; no STUN/TURN/SIP media RFC
  """

  alias GRPC.RPCError
  alias Xylon.Control.Auth
  alias Xylon.Control.Context

  @doc "Reads `authorization: Bearer ...` from the server stream metadata."
  @spec bearer_token(GRPC.Server.Stream.t()) :: {:ok, binary()} | {:error, :unauthorized}
  def bearer_token(stream) do
    headers =
      try do
        GRPC.Stream.get_headers(stream)
      rescue
        _ -> %{}
      end

    auth =
      Map.get(headers, "authorization") ||
        Map.get(headers, "Authorization")

    case auth do
      "Bearer " <> token when token != "" -> {:ok, String.trim(token)}
      "bearer " <> token when token != "" -> {:ok, String.trim(token)}
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Verifies Bearer and binds tenant/session from the request.

  Empty strings are treated as unbound (nil).
  """
  @spec authenticate(GRPC.Server.Stream.t(), binary(), binary()) ::
          {:ok, Context.t()}
          | {:error, :unauthorized | :forbidden | :failed_precondition}
  def authenticate(stream, tenant_id, session_id) do
    with {:ok, token} <- bearer_token(stream) do
      Auth.authenticate_bearer(token,
        tenant_id: nonempty(tenant_id),
        session_id: nonempty(session_id)
      )
    end
  end

  @doc "Maps Control error atoms to `GRPC.RPCError`."
  @spec rpc_error(atom()) :: RPCError.t()
  def rpc_error(:unauthorized),
    do: RPCError.exception(status: :unauthenticated, message: "unauthenticated")

  def rpc_error(:failed_precondition),
    do: RPCError.exception(status: :failed_precondition, message: "lab auth not supported")

  def rpc_error(:forbidden),
    do: RPCError.exception(status: :permission_denied, message: "forbidden")

  def rpc_error(:not_found),
    do: RPCError.exception(status: :not_found, message: "session not found")

  def rpc_error(:empty_dest),
    do: RPCError.exception(status: :not_found, message: "empty dest")

  def rpc_error(:rate_limited),
    do: RPCError.exception(status: :resource_exhausted, message: "rate limited")

  def rpc_error(:invalid_argument),
    do: RPCError.exception(status: :invalid_argument, message: "invalid argument")

  def rpc_error(:not_supported),
    do: RPCError.exception(status: :unimplemented, message: "not supported")

  def rpc_error(_),
    do: RPCError.exception(status: :internal, message: "internal")

  @doc false
  def nonempty(""), do: nil
  def nonempty(nil), do: nil
  def nonempty(bin) when is_binary(bin), do: bin
end
