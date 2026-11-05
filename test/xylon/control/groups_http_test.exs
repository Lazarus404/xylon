defmodule Xylon.Control.GroupsHttpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Context, Groups, Membership, Quota}
  alias Xylon.Control.Auth.HMAC

  @secret "groups-http-test-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Groups)
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

  defp post_json(path, body, token) do
    conn(:post, path, Jason.encode!(body))
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

  test "CRUD create list add remove delete" do
    sid = "ghttp-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})
    tok = token(sid)

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/groups", %{group_id: "team"}, tok)
    assert conn.status == 200

    conn = get_json("/v1/tenants/t1/sessions/#{sid}/groups", tok)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["groups"] == %{"team" => []}

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/groups/team/members",
        %{participant_id: "a"},
        tok
      )

    assert conn.status == 200

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/groups/team/members",
        %{participant_id: "ghost"},
        tok
      )

    assert conn.status == 404

    conn = get_json("/v1/tenants/t1/sessions/#{sid}/groups", tok)
    assert Jason.decode!(conn.resp_body)["groups"]["team"] == ["a"]

    conn = delete_json("/v1/tenants/t1/sessions/#{sid}/groups/team/members/a", tok)
    assert conn.status == 200

    conn = delete_json("/v1/tenants/t1/sessions/#{sid}/groups/team", tok)
    assert conn.status == 200
  end

  test "mutate ACL rejects without groups:mutate" do
    sid = "gacl-#{System.unique_integer([:positive])}"
    tok = token(sid, ["inject"])

    conn = post_json("/v1/tenants/t1/sessions/#{sid}/groups", %{group_id: "x"}, tok)
    assert conn.status == 403
  end

  test "resolve group dest and send ACL" do
    sid = "gres-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})
    :ok = Groups.create("t1", sid, "breakout")
    :ok = Groups.add_member("t1", sid, "breakout", "a")
    :ok = Groups.add_member("t1", sid, "breakout", "b")

    tok = token(sid)

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/dest/resolve",
        %{dest: %{"group" => "breakout"}, participant_id: "actor"},
        tok
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.sort(body["dest"]) == ["a", "b"]

    deny = token(sid, ["inject"])

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/dest/resolve",
        %{dest: %{"group" => "breakout"}},
        deny
      )

    assert conn.status == 403
  end

  test "scoped groups:send must cover every id in groups union" do
    sid = "gmulti-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})
    :ok = Groups.create("t1", sid, "g1")
    :ok = Groups.create("t1", sid, "g2")
    :ok = Groups.add_member("t1", sid, "g1", "a")
    :ok = Groups.add_member("t1", sid, "g2", "b")

    only_g1 = token(sid, ["groups:send:g1"])

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/dest/resolve",
        %{dest: %{"groups" => ["g1", "g2"]}},
        only_g1
      )

    assert conn.status == 403

    both = token(sid, ["groups:send:g1", "groups:send:g2"])

    conn =
      post_json(
        "/v1/tenants/t1/sessions/#{sid}/dest/resolve",
        %{dest: %{"groups" => ["g1", "g2"]}},
        both
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert Enum.sort(body["dest"]) == ["a", "b"]
  end

  test "remove_participant drops from groups" do
    sid = "gleave-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Groups.create("t1", sid, "g")
    :ok = Groups.add_member("t1", sid, "g", "a")
    :ok = Groups.remove_participant("t1", sid, "a")
    assert Groups.members("t1", sid, "g") == []
  end
end
