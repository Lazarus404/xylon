defmodule Xylon.Control.RecordHttpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.Context
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Recording.Registry

  @secret "record-http-test-secret"

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok = Registry.ensure_table!()
    Application.put_env(:xylon, :recording, handler: Xylon.Recording.Null)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    on_exit(fn ->
      Application.delete_env(:xylon, :control)
      Application.delete_env(:xylon, :recording)
    end)

    :ok
  end

  defp token(session_id, caps \\ ["record"]) do
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

  defp post_json(path, body, tok) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{tok}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  defp get_json(path, tok) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{tok}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  test "start get stop; second start returns 409" do
    sid = "rec-http-#{System.unique_integer([:positive])}"
    assert {:ok, _session} = Xylon.Session.create("t1", sid, :echo)
    tok = token(sid)

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/start", %{}, tok)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["recording_id"])
    assert body["sequence"] == 1
    assert body["preceded_by"] == nil
    assert body["mode"] == "tracks"

    conn = get_json("/v1/tenants/t1/sessions/#{sid}/record", tok)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["recording_id"] == body["recording_id"]

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/start", %{}, tok)
    assert conn.status == 409

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/stop", %{}, tok)
    assert conn.status == 200
    stop = Jason.decode!(conn.resp_body)
    assert stop["recording_id"] == body["recording_id"]
    assert stop["status"] == "finalizing"

    conn = get_json("/v1/tenants/t1/sessions/#{sid}/record", tok)
    assert conn.status == 404
  end

  test "record capability required when caps are non-empty" do
    sid = "rec-acl-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", sid, :echo)

    deny = token(sid, ["inject"])
    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/start", %{}, deny)
    assert conn.status == 403

    lab = token(sid, [])
    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/start", %{}, lab)
    assert conn.status == 200

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/stop", %{}, lab)
    assert conn.status == 200
  end

  test "missing session returns 404" do
    sid = "missing-#{System.unique_integer([:positive])}"
    tok = token(sid)
    conn = post_json("/v1/tenants/t1/sessions/#{sid}/record/start", %{}, tok)
    assert conn.status == 404
  end
end
