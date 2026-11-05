defmodule Xylon.Control.ModerationTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Audit, Context, Feeds, Membership, Moderation, Presence, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.{Participant, Session}

  defmodule PublishBackend do
    @moduledoc false
    @behaviour Xylon.Backend

    def id, do: :mod_publish_stub
    @impl true
    def init(session, _o) do
      {:ok,
       %{
         tenant_id: session.tenant_id,
         session_id: session.id,
         published: []
       }}
    end

    @impl true
    def participant_joined(_p, s), do: {:ok, s}

    @impl true
    def participant_left(p, s) do
      _ = Feeds.delete(s.tenant_id, s.session_id, p.id)
      {:ok, s}
    end

    @impl true
    def handle_rtp(_p, _r, s), do: {:ok, s}
    @impl true
    def handle_rtcp(_p, _r, s), do: {:ok, s}
    @impl true
    def handle_datachannel(_p, _r, _d, s), do: {:ok, s}
    @impl true
    def terminate(_r, _s), do: :ok
    @impl true
    def publish_datachannel(payload, dest, opts, state) do
      {:ok, %{state | published: [{payload, dest, opts} | state.published]}}
    end
  end

  defmodule FakePeer do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(_), do: {:ok, %{}}
    @impl true
    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
  end

  @secret "mod-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(Moderation)
    start_supervised!(Audit)
    start_supervised!(Presence)
    start_supervised!(Feeds)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      quotas: %{inject_per_minute: 120}
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(PublishBackend)
    Quota.reset()
    Moderation.reset()
    Audit.reset()

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  test "mute blocks inject but not session create" do
    sid = "mod-mute-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", sid, :mod_publish_stub)

    :ok = Moderation.set("t1", sid, "a", :mute, actor: "mod", reason: "spam")
    assert Moderation.blocked_inject?("t1", sid, "a")
    refute Moderation.blocked_join?("t1", sid, "a")

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "a",
          capabilities: ["inject"]
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{sid}/data",
        Jason.encode!(%{payload: "hi", dest: "all"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
    assert [%{action: :mute, target: "a"} | _] = Audit.list("t1", sid)
  end

  test "ban blocks HTTP offer" do
    sid = "mod-offer-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", sid, :mod_publish_stub)
    :ok = Moderation.set("t1", sid, "b", :ban)

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "b",
          capabilities: []
        },
        @secret
      )

    offer = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    c=IN IP4 0.0.0.0
    a=ice-ufrag:u
    a=ice-pwd:passwordpasswordpass
    a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
    a=setup:actpass
    a=mid:0
    a=sendrecv
    a=rtpmap:111 opus/48000/2
    """
    |> String.replace("\n", "\r\n")

    conn =
      conn(:post, "/v1/sessions/#{sid}/offer?participant_id=b", offer)
      |> put_req_header("content-type", "application/sdp")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
  end

  test "moderate HTTP requires moderate capability when caps set" do
    sid = "mod-http-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "mod",
          capabilities: ["inject"]
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{sid}/moderate",
        Jason.encode!(%{action: "mute", participant_id: "a"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
  end

  test "moderate HTTP mute succeeds with moderate cap" do
    sid = "mod-ok-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "mod",
          capabilities: ["moderate"]
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{sid}/moderate",
        Jason.encode!(%{action: "mute", participant_id: "a", reason: "x"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    assert Moderation.blocked_inject?("t1", sid, "a")
  end

  test "moderate HTTP mute rejects empty mids list" do
    sid = "mod-mids-empty-#{System.unique_integer([:positive])}"

    conn =
      post_moderate(sid, %{
        action: "mute",
        participant_id: "a",
        mids: []
      })

    assert conn.status == 400
    assert conn.resp_body == "invalid mids"
  end

  test "moderate HTTP mute accepts nonempty mids" do
    sid = "mod-mids-ok-#{System.unique_integer([:positive])}"

    conn =
      post_moderate(sid, %{
        action: "mute",
        participant_id: "a",
        mids: ["0"]
      })

    assert conn.status == 200
    assert Moderation.blocked_inject?("t1", sid, "a")
  end

  test "moderate notice:true injects moderation.notice to target" do
    sid = "mod-notice-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Xylon.Session.create("t1", sid, :mod_publish_stub)

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "mod",
          capabilities: ["moderate"]
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{sid}/moderate",
        Jason.encode!(%{
          action: "mute",
          participant_id: "a",
          reason: "spam",
          notice: true
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    state = :sys.get_state(pid)
    assert [{payload, ["a"], _opts} | _] = state.backend_state.published
    assert Jason.decode!(payload)["type"] == "moderation.notice"
    assert Jason.decode!(payload)["action"] == "mute"
  end

  test "kick without ban leaves participant, unpublishes feeds, not banned" do
    sid = "mod-kick-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :mod_publish_stub)
    assert :ok = seed_two_participants(session, "alice", "bob")
    assert :ok = Feeds.put("t1", sid, "alice", %{streams: [%{mid: "0", kind: :audio}]})
    assert :ok = Presence.subscribe("t1", sid, "viewer", self())

    conn = post_moderate(sid, %{action: "kick", participant_id: "alice", reason: "spam"})
    assert conn.status == 200

    state = :sys.get_state(session)
    refute Map.has_key?(state.participants, "alice")
    assert Map.has_key?(state.participants, "bob")
    refute Moderation.blocked_join?("t1", sid, "alice")
    assert [] = Feeds.list("t1", sid)

    assert_receive {:xylon_control_presence,
                    %{type: :feeds_diff, action: :unpublished, participant_id: "alice"}}

    assert [%{action: :kick, target: "alice"} | _] = Audit.list("t1", sid)
  end

  test "kick with ban:true leaves and bans" do
    sid = "mod-kick-ban-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :mod_publish_stub)
    assert :ok = seed_two_participants(session, "alice", "bob")

    conn =
      post_moderate(sid, %{
        action: "kick",
        participant_id: "alice",
        ban: true,
        reason: "abuse"
      })

    assert conn.status == 200
    state = :sys.get_state(session)
    refute Map.has_key?(state.participants, "alice")
    assert Moderation.blocked_join?("t1", sid, "alice")
  end

  test "kick missing participant is ok; ban still applied when requested" do
    sid = "mod-kick-miss-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Session.create("t1", sid, :mod_publish_stub)

    conn =
      post_moderate(sid, %{
        action: "kick",
        participant_id: "ghost",
        ban: true
      })

    assert conn.status == 200
    assert Moderation.blocked_join?("t1", sid, "ghost")
    assert [%{action: :kick, target: "ghost"} | _] = Audit.list("t1", sid)
  end

  test "kick without moderate capability returns 403" do
    sid = "mod-kick-acl-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "mod",
          capabilities: ["inject"]
        },
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{sid}/moderate",
        Jason.encode!(%{action: "kick", participant_id: "a"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
  end

  defp post_moderate(sid, body) do
    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "mod",
          capabilities: ["moderate"]
        },
        @secret
      )

    conn(
      :post,
      "/v1/tenants/t1/sessions/#{sid}/moderate",
      Jason.encode!(body)
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  defp seed_two_participants(session, a_id, b_id) do
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    :sys.replace_state(session, fn state ->
      %{
        state
        | participants: %{
            a_id => %Participant{id: a_id, peer_ref: peer_a},
            b_id => %Participant{id: b_id, peer_ref: peer_b}
          }
      }
    end)

    :ok
  end
end
