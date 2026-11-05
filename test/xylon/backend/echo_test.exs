defmodule Xylon.Backend.EchoTest do
  use ExUnit.Case, async: true

  alias Xylon.Backend.Echo
  alias Xylon.{Participant, Session}
  alias XMediaLib.Rtp

  test "echo rewrites RTP SSRC so the peer does not collide with its own outbound" do
    session = %Session{id: "s1", backend: Echo}
    assert {:ok, state} = Echo.init(session, [])

    p = %Participant{id: "p1", role: :echo}

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 4242,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    assert {:forward, [{^p, echoed}], state2} = Echo.handle_rtp(p, rtp, state)
    assert echoed.ssrc != 4242
    assert echoed.payload == "hi"
    assert echoed.payload_type == 111

    assert {:forward, [{^p, echoed2}], _state3} = Echo.handle_rtp(p, %{rtp | sequence_number: 2}, state2)
    assert echoed2.ssrc == echoed.ssrc
  end

  test "echo strips RTP header extensions that confuse receiver jitter / congestion control" do
    session = %Session{id: "s1", backend: Echo}
    assert {:ok, state} = Echo.init(session, [])
    p = %Participant{id: "p1", role: :echo}

    rtp = %Rtp{
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 99,
      csrcs: [1],
      extension: %Rtp.Extension{type: 0xBEDE, payload: <<1, 2, 3, 4>>},
      payload: "hi"
    }

    assert {:forward, [{^p, echoed}], _} = Echo.handle_rtp(p, rtp, state)
    assert echoed.extension == nil
    assert echoed.csrcs == []
    assert echoed.ssrc != 99
  end
end
