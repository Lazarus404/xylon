defmodule Xylon.SessionMediaReadyErrorTest do
  use ExUnit.Case, async: false

  alias Xylon.Session

  @offer """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0
  a=ice-ufrag:test
  a=ice-pwd:testpassword123456789012
  a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
  a=setup:actpass
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=rtcp-mux
  a=sendrecv
  a=mid:0
  a=rtpmap:111 opus/48000/2
  a=ssrc:1001 cname:ghost
  """
  |> String.replace("\n", "\r\n")

  defmodule FailMediaReadyBackend do
    @behaviour Xylon.Backend

    def id, do: :fail_media_ready

    def init(_session, _opts), do: {:ok, %{joined: MapSet.new(), left: []}}

    def participant_joined(%{id: id}, state) do
      {:ok, %{state | joined: MapSet.put(state.joined, id)}}
    end

    def participant_left(%{id: id}, state) do
      {:ok,
       %{
         state
         | joined: MapSet.delete(state.joined, id),
           left: [id | state.left]
       }}
    end

    def media_ready(_participant, _offer, _ctx, _state), do: {:error, :max_publishers}

    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_reason, _state), do: :ok
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(FailMediaReadyBackend)
    :ok
  end

  test "media_ready error calls participant_left and leaves no join ghost" do
    assert {:ok, session} = Session.create("t1", "media-ready-err", :fail_media_ready)

    assert {:error, :max_publishers} =
             Session.apply_offer(session, @offer, participant_id: "p1")

    state = :sys.get_state(session)
    assert state.participants == %{}
    assert MapSet.size(state.backend_state.joined) == 0
    assert "p1" in state.backend_state.left
  end
end
