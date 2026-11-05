defmodule Xylon.Signaling.WSHandlerTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Context, Membership, Moderation, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Signaling.WSHandler

  @secret "ws-hmac-secret"
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

  @host_cand "candidate:1 1 UDP 2130706431 127.0.0.1 9 typ host"

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(Moderation)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  defp push(state, map) do
    WSHandler.handle_in({Jason.encode!(map), [opcode: :text]}, state)
  end

  defp text_payload({:text, bin}) when is_binary(bin), do: bin
  defp text_payload([{:text, bin} | _]) when is_binary(bin), do: bin
  defp text_payload([text: bin]) when is_binary(bin), do: bin

  defp assert_push_text({:push, pushed, state}) do
    {text_payload(pushed), state}
  end

  defp join_offer(sid, participant_id \\ "a") do
    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: participant_id,
          capabilities: []
        },
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {joined, state} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: participant_id
        })
      )

    assert %{"type" => "joined"} = Jason.decode!(joined)

    {answer, state} = assert_push_text(push(state, %{type: "offer", sdp: @offer}))
    assert %{"type" => "answer"} = Jason.decode!(answer)
    {state, token}
  end

  test "join without token is unauthorized" do
    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "join",
          tenant_id: "t1",
          session_id: "s1",
          participant_id: "a"
        })
      )

    assert %{"type" => "error", "reason" => "unauthorized"} = Jason.decode!(body)
  end

  test "ice before offer returns not_found" do
    sid = "ws-ice-pre-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {joined, state} =
      assert_push_text(
        push(state, %{type: "join", token: token, library: "echo", participant_id: "a"})
      )

    assert %{"type" => "joined"} = Jason.decode!(joined)

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "ice",
          candidate: @host_cand,
          sdpMid: "0",
          sdpMLineIndex: 0
        })
      )

    assert %{"type" => "error", "reason" => reason} = Jason.decode!(body)
    assert reason in ["not_found", "not_connected"]
  end

  test "ice after offer returns ice_ok" do
    sid = "ws-ice-ok-#{System.unique_integer([:positive])}"
    {state, _} = join_offer(sid)

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "ice",
          candidate: @host_cand,
          sdpMid: "0",
          sdpMLineIndex: 0
        })
      )

    assert %{"type" => "ice_ok"} = Jason.decode!(body)
  end

  test "ice end-of-candidates with null candidate returns ice_ok" do
    sid = "ws-ice-eoc-#{System.unique_integer([:positive])}"
    {state, _} = join_offer(sid)

    {body, _} = assert_push_text(push(state, %{type: "ice", candidate: nil, sdpMid: "0"}))

    assert %{"type" => "ice_ok"} = Jason.decode!(body)
  end

  test "ice end-of-candidates with empty-string candidate returns ice_ok" do
    sid = "ws-ice-eoc-empty-#{System.unique_integer([:positive])}"
    {state, _} = join_offer(sid)

    {body, _} = assert_push_text(push(state, %{type: "ice", candidate: "", sdpMid: "1"}))

    assert %{"type" => "ice_ok"} = Jason.decode!(body)
  end

  test "join and offer return answer for echo" do
    sid = "ws-#{System.unique_integer([:positive])}"
    {_state, _} = join_offer(sid)
  end

  test "join accepts backend_opts on session create" do
    sid = "ws-opts-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {joined, _} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "a",
          backend_opts: %{"default_label" => "chat"}
        })
      )

    assert %{"type" => "joined", "session_id" => ^sid} = Jason.decode!(joined)
  end

  test "join rejects bad backend_opts" do
    sid = "ws-bad-opts-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "a",
          backend_opts: %{"mode" => "not_a_mode"}
        })
      )

    assert %{"type" => "error", "reason" => "bad_backend_opts"} = Jason.decode!(body)
  end

  test "banned participant cannot join" do
    sid = "ws-ban-#{System.unique_integer([:positive])}"
    :ok = Moderation.set("t1", sid, "a", :ban)

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "a"
        })
      )

    assert %{"type" => "error", "reason" => "forbidden"} = Jason.decode!(body)
  end

  test "banned participant cannot trickle ice" do
    sid = "ws-ice-ban-#{System.unique_integer([:positive])}"
    {state, _} = join_offer(sid)
    :ok = Moderation.set("t1", sid, "a", :ban)

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "ice",
          candidate: @host_cand,
          sdpMid: "0",
          sdpMLineIndex: 0
        })
      )

    assert %{"type" => "error", "reason" => "forbidden"} = Jason.decode!(body)
  end

  test "hmac join rejects participant_id that does not match token" do
    sid = "ws-pvtid-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {body, state} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "alice"
        })
      )

    assert %{"type" => "error", "reason" => "forbidden"} = Jason.decode!(body)
    assert is_nil(state.ctx)
  end

  test "hmac join accepts matching participant_id or omit" do
    sid = "ws-pvtid-ok-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {joined, state} =
      assert_push_text(
        push(state, %{type: "join", token: token, library: "echo", participant_id: "bob"})
      )

    assert %{"type" => "joined"} = Jason.decode!(joined)
    assert state.ctx.participant_id == "bob"

    {:ok, state2} = WSHandler.init(conn_id: "c2", query: %{})

    {joined2, state2} =
      assert_push_text(push(state2, %{type: "join", token: token, library: "echo"}))

    assert %{"type" => "joined"} = Jason.decode!(joined2)
    assert state2.ctx.participant_id == "bob"
  end
end
