defmodule Xylon.Control.Webhooks.Delivery do
  @moduledoc """
  HTTP POST delivery and HMAC-SHA256 signing for Control webhooks.

  ## What problem this solves

  Tenant webhook endpoints must receive signed JSON envelopes they can verify.
  Delivery POSTs via `:httpc`, signs the body with `x-xylon-signature:
  sha256=<hex>`, and retries live delivery up to three times before returning
  `{:error, :delivery_failed}` to the queue.

  ## RFCs

  HMAC-SHA256 body signing; no STUN/TURN/SIP RFC. Xylon control-plane API.

  ## Examples

      iex> sig = Xylon.Control.Webhooks.Delivery.sign("{}", "secret")
      iex> String.starts_with?(sig, "sha256=")
      true
      iex> Xylon.Control.Webhooks.Delivery.valid_signature?("{}", "secret", sig)
      true
  """

  require Logger

  alias Xylon.Control.Auth

  @header "x-xylon-signature"
  # Delays between the 3 attempts (no sleep after the final failure).
  @backoff_ms [100, 400, 1_600]

  @doc "HMAC-SHA256 signature header value: `sha256=<hex>`."
  @spec sign(binary(), binary()) :: binary()
  def sign(body, secret) when is_binary(body) and is_binary(secret) do
    mac = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(mac, case: :lower)
  end

  @doc "True when signature matches body and secret."
  @spec valid_signature?(binary(), binary(), binary()) :: boolean()
  def valid_signature?(body, secret, "sha256=" <> hex)
      when is_binary(body) and is_binary(secret) and is_binary(hex) do
    expected = sign(body, secret)

    a = :erlang.iolist_to_binary(expected)
    b = :erlang.iolist_to_binary("sha256=" <> hex)

    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  def valid_signature?(_, _, _), do: false

  @doc """
  POSTs JSON envelope to `webhook_url` with retries.

  Returns `:ok` on 2xx, `:ok` when URL/secret missing (no-op), or `{:error, reason}`.
  """
  @spec deliver(binary(), map()) :: :ok | {:error, term()}
  def deliver(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, url, secret, body} <- prepare(type, payload) do
      do_deliver(url, body, secret, 0)
    end
  end

  @doc """
  Single POST (no retries). Used by the DLQ drain loop.

  Returns `:ok` on 2xx or when URL/secret missing; otherwise `{:error, reason}`.
  """
  @spec post_once(binary(), map()) :: :ok | {:error, term()}
  def post_once(type, payload) when is_binary(type) and is_map(payload) do
    with {:ok, url, secret, body} <- prepare(type, payload) do
      post(url, body, secret)
    end
  end

  defp prepare(type, payload) do
    cfg = Auth.config()
    url = Keyword.get(cfg, :webhook_url)
    secret = Keyword.get(cfg, :webhook_secret)

    cond do
      not is_binary(url) or url == "" ->
        :ok

      not is_binary(secret) or secret == "" ->
        :ok

      true ->
        body = Jason.encode!(Map.put(payload, "type", type))
        {:ok, url, secret, body}
    end
  end

  defp do_deliver(url, body, secret, attempt) when attempt < 3 do
    case post(url, body, secret) do
      :ok ->
        :ok

      {:error, _reason} when attempt == 2 ->
        fail(url)

      {:error, _reason} ->
        Process.sleep(Enum.at(@backoff_ms, attempt))
        do_deliver(url, body, secret, attempt + 1)
    end
  end

  defp fail(url) do
    Logger.warning("xylon control webhook delivery failed url=#{url}")
    {:error, :delivery_failed}
  end

  defp post(url, body, secret) do
    headers = [
      {~c"content-type", ~c"application/json"},
      {String.to_charlist(@header), String.to_charlist(sign(body, secret))}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 5_000}], []) do
      {:ok, {{_v, status, _}, _headers, _resp}} when status in 200..299 ->
        :ok

      {:ok, {{_v, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
