defmodule Xylon.Control.Auth.JWTTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Auth.JWT
  alias Xylon.Control.Context

  @secret "jwt-test-secret-at-least-32-bytes!!"

  setup do
    jwk = JOSE.JWK.from_oct(@secret)
    {_, jwk_map} = JOSE.JWK.to_map(jwk)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :jwt,
      jwks: %{"keys" => [jwk_map]}
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    {:ok, jwk: jwk}
  end

  defp mint(jwk, claims) do
    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  test "verify returns context from claims", %{jwk: jwk} do
    token =
      mint(jwk, %{
        "tenant_id" => "t1",
        "session_id" => "s1",
        "participant_id" => "a",
        "capabilities" => ["inject"]
      })

    assert {:ok,
            %Context{
              tenant_id: "t1",
              session_id: "s1",
              participant_id: "a",
              capabilities: ["inject"]
            }} = JWT.verify(token)
  end

  test "missing tenant/session is unauthorized", %{jwk: jwk} do
    token = mint(jwk, %{"participant_id" => "a"})
    assert {:error, :unauthorized} = JWT.verify(token)
  end

  test "tampered token is unauthorized", %{jwk: jwk} do
    token =
      mint(jwk, %{
        "tenant_id" => "t1",
        "session_id" => "s1",
        "participant_id" => "a"
      })

    bad = token <> "x"
    assert {:error, :unauthorized} = JWT.verify(bad)
  end

  test "authenticate binds tenant/session via Plug", %{jwk: jwk} do
    token =
      mint(jwk, %{
        "tenant_id" => "t1",
        "session_id" => "s1",
        "participant_id" => "a",
        "capabilities" => []
      })

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")

    assert {:ok, %Context{tenant_id: "t1", session_id: "s1"}} =
             Xylon.Control.Auth.authenticate(conn, tenant_id: "t1", session_id: "s1")

    assert {:error, :forbidden} =
             Xylon.Control.Auth.authenticate(conn, tenant_id: "t1", session_id: "other")
  end
end
