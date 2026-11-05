defmodule Xylon.Control.Secrets do
  @moduledoc """
  Pluggable tenant shared-secret lookup for HMAC verify.

  ## What problem this solves

  Multi-tenant HMAC auth needs per-tenant keys with optional dual-key rotation.
  Secrets exposes a single `get/1` callback resolved from
  `config :xylon, :control, secrets: {Module, opts}`. Default adapter is
  `Secrets.Config` (global `hmac_secret`).

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  alias Xylon.Control.Auth
  alias Xylon.Control.Secrets.Record

  @callback get(tenant_id :: String.t(), opts :: keyword()) ::
              {:ok, Record.t()} | {:error, :not_found}

  @doc "Looks up secret material for `tenant_id` via the configured adapter."
  @spec get(String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def get(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    {mod, opts} = adapter()
    mod.get(tenant_id, opts)
  end

  def get(_), do: {:error, :not_found}

  defp adapter do
    case Keyword.get(Auth.config(), :secrets) do
      {mod, opts} when is_atom(mod) and is_list(opts) -> {mod, opts}
      mod when is_atom(mod) and not is_nil(mod) -> {mod, []}
      _ -> {Xylon.Control.Secrets.Config, []}
    end
  end
end
