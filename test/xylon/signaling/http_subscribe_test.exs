defmodule Xylon.Signaling.HTTPSubscribeTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Xylon.Control.{Context, Membership, Moderation, Quota}
  alias Xylon.Control.Auth.HMAC

  @secret "http-sub-hmac-secret"

  defmodule SubBackend do
    @behaviour Xylon.Backend

    def id, do: :http_sub

    def init(_session, _opts), do: {:ok, %{subs: [], updates: [], layers: []}}
    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}
    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_r, _s), do: :ok

    def subscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: [{sub, pub, mid} | state.subs]}}
    end

    def unsubscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: List.delete(state.subs, {sub, pub, mid})}}
    end

    def set_substream(sub, pub, mid, opts, state) do
      {:ok, %{state | layers: [{sub, pub, mid, opts} | state.layers]}}
    end

    def update_subscriptions(sub, streams, _opts, state) do
      {:ok, %{state | updates: [{sub, streams} | state.updates]}}
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(SubBackend)
    :ok
  end

  test "POST subscribe and unsubscribe" do
    sid = "http-sub-1"

    conn =
      conn(
        :post,
        "/v1/sessions",
        Jason.encode!(%{session_id: sid, library: "http_sub"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body = Jason.encode!(%{publisher_id: "a", mid: "0"})

    conn =
      conn(:post, "/v1/sessions/#{sid}/subscribe?participant_id=b", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204

    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", "a", "0"}] = :sys.get_state(session).backend_state.subs

    conn =
      conn(:post, "/v1/sessions/#{sid}/unsubscribe?participant_id=b", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204
    assert [] = :sys.get_state(session).backend_state.subs
  end

  test "POST update replaces subscriptions" do
    sid = "http-update-1"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: sid, library: "http_sub"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body =
      Jason.encode!(%{
        streams: [%{publisher_id: "a", mid: "0"}, %{publisher_id: "c"}]
      })

    conn =
      conn(:post, "/v1/sessions/#{sid}/update?participant_id=b", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204

    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", streams}] = :sys.get_state(session).backend_state.updates
    assert length(streams) == 2
  end

  test "POST set_substream passes substream and rid" do
    sid = "http-layer-1"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: sid, library: "http_sub"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body = Jason.encode!(%{publisher_id: "a", mid: "1", substream: 2, rid: "f"})

    conn =
      conn(:post, "/v1/sessions/#{sid}/set_substream?participant_id=b", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204

    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", "a", "1", opts}] = :sys.get_state(session).backend_state.layers
    assert Keyword.get(opts, :substream) == 2
    assert Keyword.get(opts, :rid) == "f"
  end

  test "subscribe on echo returns not supported" do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    sid = "http-sub-echo"

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: sid, library: "echo"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body = Jason.encode!(%{publisher_id: "a", mid: "1"})

    conn =
      conn(:post, "/v1/sessions/#{sid}/subscribe?participant_id=b", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-tenant-id", "t1")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 400
    assert conn.resp_body == "not supported"
  end

  test "hmac subscribe rejects mismatched participant_id query" do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(Moderation)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      quotas: %{inject_per_minute: 120}
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)

    sid = "http-pvtid-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: sid, library: "http_sub"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body = Jason.encode!(%{publisher_id: "a", mid: "0"})

    conn =
      conn(:post, "/v1/sessions/#{sid}/subscribe?participant_id=alice", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
  end

  test "hmac subscribe uses token participant_id when query omitted or matches" do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(Moderation)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      quotas: %{inject_per_minute: 120}
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)

    sid = "http-pvtid-ok-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    conn =
      conn(:post, "/v1/sessions", Jason.encode!(%{session_id: sid, library: "http_sub"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 201

    body = Jason.encode!(%{publisher_id: "a", mid: "0"})

    conn =
      conn(:post, "/v1/sessions/#{sid}/subscribe", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204

    session = Xylon.Session.whereis("t1", sid)
    assert [{"bob", "a", "0"}] = :sys.get_state(session).backend_state.subs

    conn =
      conn(:post, "/v1/sessions/#{sid}/subscribe?participant_id=bob", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 204
  end
end
