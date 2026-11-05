defmodule Xylon.Control.PresencePushTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Membership, Presence}

  setup do
    start_supervised!(Membership)
    start_supervised!(Presence)
    :ok
  end

  test "snapshot_payload mirrors list/2" do
    :ok = Membership.join("t1", "s1", "a", %{role: :echo, joined_at: 100})
    assert Presence.list("t1", "s1") == Presence.snapshot_payload("t1", "s1")
    assert %{"a" => %{"joined_at" => 100}} = Presence.snapshot_payload("t1", "s1")
  end

  test "subscribe receives broadcast_diff join and leave" do
    assert :ok = Presence.subscribe("t1", "s1", "viewer", self())

    :ok =
      Presence.broadcast_diff("t1", "s1", %{
        action: :join,
        participant_id: "a",
        role: :echo,
        joined_at: 200,
        meta: %{}
      })

    assert_receive {:xylon_control_presence,
                    %{
                      type: :diff,
                      action: :join,
                      participant_id: "a",
                      joined_at: 200
                    }}

    :ok =
      Presence.broadcast_diff("t1", "s1", %{
        action: :leave,
        participant_id: "a"
      })

    assert_receive {:xylon_control_presence, %{type: :diff, action: :leave, participant_id: "a"}}
  end

  test "unsubscribe and DOWN stop delivery" do
    assert :ok = Presence.subscribe("t1", "s1", "viewer", self())
    assert :ok = Presence.unsubscribe("t1", "s1", "viewer")

    :ok =
      Presence.broadcast_diff("t1", "s1", %{
        action: :join,
        participant_id: "a",
        role: :echo,
        joined_at: 1,
        meta: %{}
      })

    refute_receive {:xylon_control_presence, _}, 100
  end

  test "broadcast_talking reaches room subscribers" do
    assert :ok = Presence.subscribe("t1", "s1", "viewer", self())

    :ok =
      Presence.broadcast_talking("t1", "s1", %{
        type: :talking,
        participant_id: "a",
        audio_level_dbov_avg: 12.5
      })

    assert_receive {:xylon_control_presence,
                    %{
                      type: :talking,
                      participant_id: "a",
                      audio_level_dbov_avg: 12.5
                    }}

    :ok =
      Presence.broadcast_talking("t1", "s1", %{
        type: :stopped_talking,
        participant_id: "a",
        audio_level_dbov_avg: 80.0
      })

    assert_receive {:xylon_control_presence,
                    %{type: :stopped_talking, participant_id: "a", audio_level_dbov_avg: 80.0}}
  end
end
