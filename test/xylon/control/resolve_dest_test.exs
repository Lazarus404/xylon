defmodule Xylon.Control.ResolveDestTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Context, Membership, Quota}
  alias Xylon.Control.Auth.HMAC

  @secret "resolve-dest-test-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      quotas: %{inject_per_minute: 120}
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  test "resolve without token is 401" do
    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/s1/dest/resolve",
        Jason.encode!(%{dest: "all"})
      )
      |> put_req_header("content-type", "application/json")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 401
  end

  test "resolve all and role filter" do
    session_id = "res-ok-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", session_id, "a", %{role: "user"})
    :ok = Membership.join("t1", session_id, "m", %{role: "moderator"})

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: session_id,
          participant_id: "a",
          capabilities: []
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{session_id}/dest/resolve",
        Jason.encode!(%{dest: "all", participant_id: "a"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ok" => true, "dest" => "all"}

    conn2 =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{session_id}/dest/resolve",
        Jason.encode!(%{dest: %{"role" => "moderator"}, participant_id: "a"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn2.status == 200
    body = Jason.decode!(conn2.resp_body)
    assert body["ok"] == true
    assert body["dest"] == ["m"]
  end

  test "empty except is 404" do
    session_id = "res-empty-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", session_id, "a", %{})

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: session_id,
          participant_id: "a",
          capabilities: []
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{session_id}/dest/resolve",
        Jason.encode!(%{dest: "except", participant_id: "a"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 404
    assert conn.resp_body =~ "empty dest"
  end
end
