defmodule Xylon.Control.SessionsListHttpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.Context
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Membership

  @secret "sessions-list-http-secret"

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    start_supervised!(Membership)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  defp token(caps \\ ["sessions"]) do
    HMAC.mint(
      %Context{
        tenant_id: "t1",
        session_id: "any",
        participant_id: "actor",
        capabilities: caps
      },
      @secret
    )
  end

  defp get_json(path, tok) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{tok}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  test "lists live sessions with Membership participant_count; gone after stop" do
    sid = "list-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})

    conn = get_json("/v1/tenants/t1/sessions", token())
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["sessions"])

    row = Enum.find(body["sessions"], &(&1["session_id"] == sid))
    assert row
    assert row["participant_count"] == 2
    assert row["participant_count"] == map_size(Membership.list("t1", sid))
    assert is_binary(row["node"]) and row["node"] != ""
    assert is_binary(row["region"]) and row["region"] != ""

    GenServer.stop(session)
    wait_until_absent("t1", sid)

    conn = get_json("/v1/tenants/t1/sessions", token())
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    refute Enum.any?(body["sessions"], &(&1["session_id"] == sid))
  end

  test "empty live room listed with count 0; apply_offer bumps Membership count" do
    sid = "list-join-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)

    conn = get_json("/v1/tenants/t1/sessions", token())
    assert conn.status == 200
    row = Enum.find(Jason.decode!(conn.resp_body)["sessions"], &(&1["session_id"] == sid))
    assert row["participant_count"] == 0

    offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    c=IN IP4 0.0.0.0
    a=ice-ufrag:chromeUfrag
    a=ice-pwd:chromepasswordchromepass
    a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
    a=setup:actpass
    a=mid:0
    a=rtcp-mux
    a=sendrecv
    a=rtpmap:111 opus/48000/2
    """
    |> String.replace("\n", "\r\n")

    assert {:ok, _} = Xylon.Session.apply_offer(session, offer, participant_id: "alice")

    conn = get_json("/v1/tenants/t1/sessions", token())
    row = Enum.find(Jason.decode!(conn.resp_body)["sessions"], &(&1["session_id"] == sid))
    assert row["participant_count"] == 1
    assert row["participant_count"] == map_size(Membership.list("t1", sid))
  end

  test "list is tenant-scoped" do
    sid_a = "list-ta-#{System.unique_integer([:positive])}"
    sid_b = "list-tb-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", sid_a, :echo)
    assert {:ok, _} = Xylon.Session.create("t2", sid_b, :echo)

    conn = get_json("/v1/tenants/t1/sessions", token())
    assert conn.status == 200
    ids = Enum.map(Jason.decode!(conn.resp_body)["sessions"], & &1["session_id"])
    assert sid_a in ids
    refute sid_b in ids
  end

  test "sessions capability required when caps are non-empty" do
    sid = "list-acl-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", sid, :echo)

    deny = token(["inject"])
    conn = get_json("/v1/tenants/t1/sessions", deny)
    assert conn.status == 403

    lab = token([])
    conn = get_json("/v1/tenants/t1/sessions", lab)
    assert conn.status == 200
    assert %{"sessions" => sessions} = Jason.decode!(conn.resp_body)
    assert Enum.any?(sessions, &(&1["session_id"] == sid))
  end

  defp wait_until_absent(tenant_id, session_id, attempts \\ 50) do
    case Registry.lookup(Xylon.Registry, {tenant_id, session_id}) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_until_absent(tenant_id, session_id, attempts - 1)

      _ ->
        flunk("session still in Registry after stop")
    end
  end
end
