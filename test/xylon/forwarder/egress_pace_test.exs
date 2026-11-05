defmodule Xylon.Forwarder.EgressPaceTest do
  use ExUnit.Case, async: true

  alias Xylon.Forwarder.EgressPace
  alias XMediaLib.Rtp

  defp video(ts, seq, payload \\ <<"vvvv">>) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: seq,
      timestamp: ts,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: payload
    }
  end

  defp audio(ts, seq) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: seq,
      timestamp: ts,
      ssrc: 2,
      csrcs: [],
      extension: nil,
      payload: <<"a">>
    }
  end

  test "same-timestamp video burst is immediate" do
    peer = self()
    pace = %{}
    now = 1_000_000

    {due1, catch1, key} = EgressPace.due_for(pace, peer, video(9000, 1), now)
    assert due1 == now
    refute catch1
    pace = EgressPace.put_after(pace, key, video(9000, 1), due1, catch1)

    {due2, catch2, key} = EgressPace.due_for(pace, peer, video(9000, 2), now)
    refute catch2
    assert due2 == now
    pace = EgressPace.put_after(pace, key, video(9000, 2), due2, catch2)

    {due3, _catch3, _key} = EgressPace.due_for(pace, peer, video(9000, 3), now)
    assert due3 == now
  end

  test "timestamp step does not hold (passthrough preserves publisher timing)" do
    peer = self()
    pace = %{}
    now = 2_000_000
    pkt1 = video(0, 1)
    {due1, c1, key} = EgressPace.due_for(pace, peer, pkt1, now)
    pace = EgressPace.put_after(pace, key, pkt1, due1, c1)

    # Next frame "arrives" only 10ms later (early vs 33ms RTP step).
    # Re-clocking to RTP would hold ~23ms; passthrough must not.
    early = now + 10_000
    pkt2 = video(3000, 2)
    {due2, c2, _} = EgressPace.due_for(pace, peer, pkt2, early)
    refute c2
    assert due2 == early
  end

  test "audio is not paced" do
    peer = self()
    pace = %{}
    now = 4_000_000
    {due1, c1, key} = EgressPace.due_for(pace, peer, audio(0, 1), now)
    assert due1 == now
    pace = EgressPace.put_after(pace, key, audio(0, 1), due1, c1)

    {due2, _c2, _} = EgressPace.due_for(pace, peer, audio(960, 2), now)
    assert due2 == now
  end

  test "wait_plan uses immediate for sub-ms and floor ms otherwise" do
    assert EgressPace.wait_plan(1_000_000, 1_000_000) == :immediate
    assert EgressPace.wait_plan(1_000_500, 1_000_000) == :immediate
    assert EgressPace.wait_plan(1_001_000, 1_000_000) == {:delay_ms, 1}
    assert EgressPace.wait_plan(1_033_333, 1_000_000) == {:delay_ms, 33}
  end
end
