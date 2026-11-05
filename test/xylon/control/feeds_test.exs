defmodule Xylon.Control.FeedsTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Feeds, Presence}

  setup do
    start_supervised!(Presence)
    start_supervised!(Feeds)
    :ok = Feeds.clear("t1", "s1")
    :ok
  end

  test "put list and snapshot_payload" do
    assert :ok =
             Feeds.put("t1", "s1", "alice", %{
               streams: [
                 %{mid: "0", kind: :audio, codec: "opus"},
                 %{mid: "1", kind: :video, codec: "VP8"}
               ]
             })

    pubs = Feeds.snapshot_payload("t1", "s1")
    assert length(pubs) == 1
    [alice] = pubs
    assert alice.participant_id == "alice"

    assert alice.streams == [
             %{mid: "0", kind: "audio", codec: "opus"},
             %{mid: "1", kind: "video", codec: "VP8"}
           ]
  end

  test "put broadcasts feeds.diff published" do
    assert :ok = Presence.subscribe("t1", "s1", "viewer", self())

    assert :ok =
             Feeds.put("t1", "s1", "alice", %{
               streams: [%{mid: "0", kind: :audio, codec: "opus"}]
             })

    assert_receive {:xylon_control_presence,
                    %{
                      type: :feeds_diff,
                      action: :published,
                      participant_id: "alice",
                      streams: [%{mid: "0", kind: "audio", codec: "opus"}]
                    }}
  end

  test "delete broadcasts unpublished and removes from list" do
    assert :ok = Presence.subscribe("t1", "s1", "viewer", self())

    assert :ok =
             Feeds.put("t1", "s1", "alice", %{streams: [%{mid: "0", kind: :audio}]})

    assert_receive {:xylon_control_presence, %{type: :feeds_diff, action: :published}}

    assert :ok = Feeds.delete("t1", "s1", "alice")

    assert_receive {:xylon_control_presence,
                    %{
                      type: :feeds_diff,
                      action: :unpublished,
                      participant_id: "alice",
                      streams: [%{mid: "0", kind: "audio"}]
                    }}

    assert [] = Feeds.list("t1", "s1")
  end

  test "clear drops session feeds without per-id broadcast" do
    assert :ok =
             Feeds.put("t1", "s1", "a", %{streams: [%{mid: "0", kind: :audio}]})

    assert :ok =
             Feeds.put("t1", "s1", "b", %{streams: [%{mid: "1", kind: :video}]})

    assert :ok = Feeds.clear("t1", "s1")
    assert [] = Feeds.list("t1", "s1")
  end
end
