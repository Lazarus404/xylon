defmodule Xylon.Control.Secrets.Config do
  @moduledoc """
  Secrets adapter using the global `hmac_secret` from control config.

  ## What problem this solves

  Single-tenant labs and migrations need HMAC verify without an external secret
  store. Config returns one `Record` for all tenants (or only
  `hmac_config_tenant_id` when set).

  ## Internal

  Default `Secrets` behaviour implementation.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  @behaviour Xylon.Control.Secrets

  alias Xylon.Control.Auth
  alias Xylon.Control.Secrets.Record

  @doc false
  @spec get(String.t(), keyword()) :: {:ok, Record.t()} | {:error, :not_found}
  def get(tenant_id, _opts \\ []) when is_binary(tenant_id) do
    secret = Auth.hmac_secret()
    gate = Keyword.get(Auth.config(), :hmac_config_tenant_id)

    cond do
      not is_binary(secret) or secret == "" ->
        {:error, :not_found}

      is_binary(gate) and gate != "" and gate != tenant_id ->
        {:error, :not_found}

      true ->
        {:ok, %Record{current: secret, previous: nil, previous_expires_at: nil, flags: %{}}}
    end
  end
end
