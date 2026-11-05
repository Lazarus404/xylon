defmodule Xylon.Signaling.HTTPTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @offer """
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

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "health is public" do
    conn =
      conn(:get, "/health")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "create requires x-tenant-id" do
    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: "s1", library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 401
  end

  test "create without library uses default_backend" do
    Application.put_env(:xylon, :default_backend, :echo)
    session_id = "http-default-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201
    assert %{"session_id" => ^session_id, "library" => "echo"} = Jason.decode!(conn.resp_body)
  end

  test "create with unknown library returns 400" do
    # Atom never interned in this VM -- must not crash or look like missing field.
    name = "no_such_library_#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: "s-unk", library: name}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 400
    assert conn.resp_body == "unknown library"
  end

  test "offer returns answer for attached echo" do
    session_id = "http-s1-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    conn2 =
      conn(:post, "/v1/sessions/#{session_id}/offer", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn2.status == 200
    assert conn2.resp_body =~ "a=fingerprint:"
  end

  test "create accepts backend_opts" do
    session_id = "http-opts-#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        session_id: session_id,
        library: "echo",
        backend_opts: %{mode: "fanout_except_sender", default_label: "chat"}
      })

    conn =
      conn(:post, "/v1/sessions", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    pid = Xylon.Session.whereis("t1", session_id)
    assert is_pid(pid)
  end

  test "second offer with participant_id joins room" do
    session_id = "http-multi-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    conn_a =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_a.status == 200

    conn_b =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=b", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_b.status == 200

    state = :sys.get_state(Xylon.Session.whereis("t1", session_id))
    assert Map.has_key?(state.participants, "a")
    assert Map.has_key?(state.participants, "b")
  end

  test "second offer without participant_id is 400" do
    session_id = "http-need-pid-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    _ =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    conn2 =
      conn(:post, "/v1/sessions/#{session_id}/offer", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn2.status == 400
    assert conn2.resp_body =~ "participant_id"
  end

  test "DELETE participant then re-offer same id succeeds" do
    session_id = "http-leave-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    conn_a =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_a.status == 200

    del =
      conn(:delete, "/v1/sessions/#{session_id}/participants/a")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    # Last participant leave stops Session
    assert del.status in [204, 404]

    # Recreate if session stopped
    _ =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    conn_again =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_again.status == 200
  end

  test "re-offer same participant_id is rejected without DELETE" do
    session_id = "http-replace-#{System.unique_integer([:positive])}"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: session_id, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    conn_a =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_a.status == 200

    conn_again =
      conn(:post, "/v1/sessions/#{session_id}/offer?participant_id=a", @offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn_again.status == 409
    assert Process.alive?(Xylon.Session.whereis("t1", session_id))
  end
end
