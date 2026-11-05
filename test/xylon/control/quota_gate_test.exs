defmodule Xylon.Control.QuotaGateTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Context, Membership, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Session
  alias Xylon.Signaling.WSHandler

  @secret "quota-gate-secret"

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
    start_supervised!(Membership)
    start_supervised!(Quota)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      quotas: %{join_per_minute: 1, max_participants: 1, inject_per_minute: 120}
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    Quota.reset()

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  defp ws_push(state, map) do
    WSHandler.handle_in({Jason.encode!(map), [opcode: :text]}, state)
  end

  defp joined_payload({:push, frames, state}) when is_list(frames) do
    {:text, body} = List.first(frames)
    {Jason.decode!(body), state}
  end

  defp joined_payload({:push, {:text, body}, state}) do
    {Jason.decode!(body), state}
  end

  test "WS join_per_minute rejects second join in same minute" do
    sid = "join-#{System.unique_integer([:positive])}"

    token_a =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    token_b =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "b", capabilities: []},
        @secret
      )

    {:ok, state_a} = WSHandler.init([])
    {first, _} = joined_payload(ws_push(state_a, %{type: "join", token: token_a, library: "echo"}))
    assert %{"type" => "joined"} = first

    {:ok, state_b} = WSHandler.init([])
    {second, _} = joined_payload(ws_push(state_b, %{type: "join", token: token_b, library: "echo"}))
    assert %{"type" => "error", "reason" => "rate_limited"} = second
  end

  test "HTTP create returns 429 when join quota exceeded" do
    sid = "http-join-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "host", capabilities: []},
        @secret
      )

    body = Jason.encode!(%{session_id: sid, library: "echo"})

    conn1 =
      conn(:post, "/v1/sessions", body)
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn1.status == 201

    conn2 =
      conn(:post, "/v1/sessions", body)
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn2.status == 429
  end

  test "max_participants blocks second distinct peer; same id is participant_exists" do
    sid = "max-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Session.create("t1", sid, :echo)

    assert {:ok, _answer} = Session.apply_offer(pid, @offer, participant_id: "a")
    assert {:error, :rate_limited} = Session.apply_offer(pid, @offer, participant_id: "b")
    assert {:error, :participant_exists} = Session.apply_offer(pid, @offer, participant_id: "a")

    assert Map.has_key?(:sys.get_state(pid).participants, "a")
    refute Map.has_key?(:sys.get_state(pid).participants, "b")
  end

  test "emit_exceeded is callable for join kind" do
    assert :ok = Quota.emit_exceeded("t1", "s1", "join")
  end
end
