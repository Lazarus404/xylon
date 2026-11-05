defmodule Xylon.Control.Secrets.Local do
  @moduledoc """
  Secrets adapter that fetches tenant keys from an HTTP secret store.

  ## What problem this solves

  Production multi-tenant deployments store rotating HMAC keys outside the
  media node. Local GETs
  `/v1/tenants/:tenant_id?reveal=1` from xylon-simple-secret-store (or any
  compatible service) and maps the JSON body to `Secrets.Record`.

  Options: `:url` (base, required), optional `:timeout_ms` (default 2000).

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  @behaviour Xylon.Control.Secrets

  alias Xylon.Control.Secrets.Record

  @doc false
  @spec get(String.t(), keyword()) :: {:ok, Record.t()} | {:error, :not_found}
  def get(tenant_id, opts) when is_binary(tenant_id) do
    base = Keyword.get(opts, :url) || Keyword.get(opts, :base_url)

    if not is_binary(base) or base == "" do
      {:error, :not_found}
    else
      timeout = Keyword.get(opts, :timeout_ms, 2000)
      url =
        String.trim_trailing(base, "/") <>
          "/v1/tenants/" <> URI.encode(tenant_id, &URI.char_unreserved?/1) <> "?reveal=1"

      case request_json(url, timeout) do
        {:ok, status, body} when status in 200..299 ->
          Record.from_map(body)

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp request_json(url, timeout) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [{:timeout, timeout}, {:connect_timeout, timeout}], []) do
      {:ok, {{_, status, _}, _headers, body}} ->
        case Jason.decode(IO.iodata_to_binary(body)) do
          {:ok, map} when is_map(map) -> {:ok, status, map}
          _ -> {:error, :bad_json}
        end

      _ ->
        {:error, :http}
    end
  end
end
