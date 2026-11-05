defmodule Xylon.Control.Auth.JWT do
  @moduledoc """
  JWT bearer verification via JWKS for Control auth.

  ## What problem this solves

  Production tenants often already issue JWTs from an identity provider. This
  module verifies RS256/ES256/HS256 tokens against a configured JWKS URL (or
  inline JWKS in tests), maps claims to `Context`, and optionally checks `iss`
  and `aud`. Expected claims: `tenant_id`, `session_id`, `participant_id`,
  optional `capabilities`.

  ## RFCs

  - [RFC 7519](https://www.rfc-editor.org/rfc/rfc7519) -- JSON Web Token
  - [RFC 7517](https://www.rfc-editor.org/rfc/rfc7517) -- JSON Web Key Set
  """

  alias Xylon.Control.Auth
  alias Xylon.Control.Context

  @cache :xylon_control_jwks_cache

  @doc "Verifies a JWT using configured JWKS URL or inline `:jwks` map (tests)."
  @spec verify(binary(), keyword()) :: {:ok, Context.t()} | {:error, :unauthorized}
  def verify(token, opts \\ []) when is_binary(token) do
    with {:ok, jwks} <- fetch_jwks(opts),
         {:ok, claims} <- verify_token(token, jwks),
         :ok <- check_iss_aud(claims, opts),
         {:ok, ctx} <- context_from_claims(claims) do
      {:ok, ctx}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_jwks(opts) do
    case Keyword.get(opts, :jwks) || Keyword.get(Auth.config(), :jwks) do
      map when is_map(map) ->
        {:ok, map}

      _ ->
        case Keyword.get(opts, :jwks_url) || Keyword.get(Auth.config(), :jwks_url) do
          url when is_binary(url) and url != "" ->
            cached_jwks(url)

          _ ->
            {:error, :no_jwks}
        end
    end
  end

  defp cached_jwks(url) do
    ensure_cache()
    now = System.system_time(:second)

    case :ets.lookup(@cache, url) do
      [{^url, jwks, exp}] when exp > now ->
        {:ok, jwks}

      _ ->
        case http_get_json(url) do
          {:ok, jwks} when is_map(jwks) ->
            :ets.insert(@cache, {url, jwks, now + 300})
            {:ok, jwks}

          _ ->
            {:error, :jwks_fetch}
        end
    end
  end

  defp http_get_json(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(IO.iodata_to_binary(body))

      _ ->
        {:error, :http}
    end
  end

  defp verify_token(token, %{"keys" => keys}) when is_list(keys) do
    Enum.find_value(keys, {:error, :no_key}, fn jwk_map ->
      try do
        jwk = JOSE.JWK.from_map(jwk_map)

        case JOSE.JWT.verify_strict(jwk, ["RS256", "ES256", "HS256"], token) do
          {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
          _ -> nil
        end
      rescue
        _ -> nil
      end
    end)
  end

  defp verify_token(token, jwk_map) when is_map(jwk_map) do
    verify_token(token, %{"keys" => [jwk_map]})
  end

  defp check_iss_aud(claims, opts) do
    cfg = Auth.config()
    iss = Keyword.get(opts, :jwt_iss) || Keyword.get(cfg, :jwt_iss)
    aud = Keyword.get(opts, :jwt_aud) || Keyword.get(cfg, :jwt_aud)

    cond do
      is_binary(iss) and Map.get(claims, "iss") != iss -> {:error, :bad_iss}
      is_binary(aud) and not aud_ok?(claims, aud) -> {:error, :bad_aud}
      true -> :ok
    end
  end

  defp aud_ok?(claims, aud) do
    case Map.get(claims, "aud") do
      ^aud -> true
      list when is_list(list) -> aud in list
      _ -> false
    end
  end

  defp context_from_claims(claims) do
    tenant = Map.get(claims, "tenant_id")
    session = Map.get(claims, "session_id")
    participant = Map.get(claims, "participant_id") || "p1"
    caps = Map.get(claims, "capabilities") || Map.get(claims, "cap") || []

    if is_binary(tenant) and tenant != "" and is_binary(session) and session != "" do
      {:ok,
       %Context{
         tenant_id: tenant,
         session_id: session,
         participant_id: participant,
         capabilities: caps
       }}
    else
      {:error, :unauthorized}
    end
  end

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined ->
        :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @cache
    end
  end
end
