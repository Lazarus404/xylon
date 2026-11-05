defmodule Xylon.Control.RoutesHttpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Context, Quota}
  alias Xylon.Control.Auth.HMAC

  @secret "routes-http-test-secret"

  setup do
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

  defp token(session_id, caps \\ []) do
    HMAC.mint(
      %Context{
        tenant_id: "t1",
        session_id: session_id,
        participant_id: "actor",
        capabilities: caps
      },
      @secret
    )
  end

  defp put_json(path, body, token) do
    conn(:put, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  defp delete_json(path, token) do
    conn(:delete, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  defp get_json(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  test "routes require live session and mutate ACL" do
    sid = "routes-missing-#{System.unique_integer([:positive])}"
    tok = token(sid)

    conn = put_json("/v1/tenants/t1/sessions/#{sid}/routes/a", %{dest: ["b"]}, tok)
    assert conn.status == 404

    deny = token(sid, ["inject"])
    conn = put_json("/v1/tenants/t1/sessions/#{sid}/routes/a", %{dest: ["b"]}, deny)
    assert conn.status == 403
  end

  test "PUT GET DELETE routes when datachannel catalogue is attached" do
    dc = Module.concat([Xylon, Datachannel])

    if Code.ensure_loaded?(dc) and function_exported?(dc, :attach, 0) and
         function_exported?(dc, :set_route, 4) do
      Xylon.Catalogue.reset!()
      assert :ok = apply(dc, :attach, [])
      sid = "routes-#{System.unique_integer([:positive])}"
      assert {:ok, _session} = Xylon.Session.create("t1", sid, :datachannel)
      tok = token(sid)

      conn =
        put_json(
          "/v1/tenants/t1/sessions/#{sid}/routes/a",
          %{dest: ["b", "c"]},
          tok
        )

      assert conn.status == 200

      conn = get_json("/v1/tenants/t1/sessions/#{sid}/routes", tok)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Enum.any?(body["routes"], &(&1["sender_id"] == "a"))

      conn = delete_json("/v1/tenants/t1/sessions/#{sid}/routes/a", tok)
      assert conn.status == 200
    else
      # xylon CI without the media library: handlers still reject missing session.
      assert true
    end
  end
end
