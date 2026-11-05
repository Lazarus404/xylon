defmodule Xylon.Trunk.AnnounceLocalTest do
  use ExUnit.Case, async: false

  alias Xylon.Participant
  alias Xylon.Session
  alias Xylon.Trunk.{Announce, Manager}

  @master_key <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @master_salt <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>

  setup do
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    sid = "announce-#{System.unique_integer([:positive])}"
    assert {:ok, session_a} = Session.create("t1", sid, :echo)
    assert {:ok, session_b} = Session.create("t1", "#{sid}-b", :echo)

    on_exit(fn ->
      Session.hangup(session_a)
      Session.hangup(session_b)
    end)

    %{session_a: session_a, session_b: session_b, sid: sid}
  end

  test "announce installs synthetic remote participant on far session", %{
    session_a: session_a,
    session_b: session_b,
    sid: sid
  } do
    assert {:ok, %{a: _pa, b: _pb}} =
             Manager.connect_pair(session_a, session_b,
               id_a: "trunk_ab",
               id_b: "trunk_ba",
               master_key: @master_key,
               master_salt: @master_salt
             )

    announcement =
      Announce.new(
        session_key: {"t1", sid},
        from_edge: :edge_a,
        participants: [%{id: "remote_pub", role: :publisher, labels: ["chat"]}],
        tracks: [
          %{publisher_id: "remote_pub", mid: "0", ssrc: 99, kind: :audio}
        ]
      )

    assert :ok = Manager.announce_tracks(session_b, announcement)

    state = :sys.get_state(session_b)
    assert %Participant{id: "remote_pub", role: :publisher, meta: meta} =
             state.participants["remote_pub"]

    assert meta[:remote] == true
    assert meta[:tracks] == announcement.tracks
  end

  test "announce is control-only (no RTP payload in announcement)", %{
    session_b: session_b,
    sid: sid
  } do
    announcement =
      Announce.new(
        session_key: {"t1", sid},
        participants: [%{id: "p", role: :publisher, labels: []}],
        tracks: []
      )

    refute Map.has_key?(announcement, :rtp)
    refute Map.has_key?(announcement, :payload)
    assert Announce.valid?(announcement)
    assert :ok = Manager.announce_tracks(session_b, announcement)
  end
end
