defmodule Xylon.Control.GroupsUnitTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Groups, Membership}

  setup do
    start_supervised!(Membership)
    start_supervised!(Groups)
    tid = "tg-#{System.unique_integer([:positive])}"
    sid = "sg-#{System.unique_integer([:positive])}"
    Groups.clear(tid, sid)
    Membership.clear(tid, sid)
    {:ok, tid: tid, sid: sid}
  end

  test "create list add remove delete", %{tid: tid, sid: sid} do
    :ok = Membership.join(tid, sid, "a", %{})
    :ok = Membership.join(tid, sid, "b", %{})

    assert :ok = Groups.create(tid, sid, "breakout")
    assert {:error, :already_exists} = Groups.create(tid, sid, "breakout")
    assert Groups.list(tid, sid) == %{"breakout" => []}

    assert :ok = Groups.add_member(tid, sid, "breakout", "a")
    assert :ok = Groups.add_member(tid, sid, "breakout", "b")
    assert Enum.sort(Groups.members(tid, sid, "breakout")) == ["a", "b"]

    assert {:error, :not_in_session} = Groups.add_member(tid, sid, "breakout", "ghost")
    assert {:error, :not_found} = Groups.add_member(tid, sid, "missing", "a")

    assert :ok = Groups.remove_member(tid, sid, "breakout", "a")
    assert Groups.members(tid, sid, "breakout") == ["b"]

    assert :ok = Groups.delete(tid, sid, "breakout")
    assert Groups.list(tid, sid) == %{}
    assert {:error, :not_found} = Groups.delete(tid, sid, "breakout")
  end

  test "remove_participant clears reverse index", %{tid: tid, sid: sid} do
    :ok = Membership.join(tid, sid, "a", %{})
    :ok = Membership.join(tid, sid, "b", %{})
    :ok = Groups.create(tid, sid, "g1")
    :ok = Groups.create(tid, sid, "g2")
    :ok = Groups.add_member(tid, sid, "g1", "a")
    :ok = Groups.add_member(tid, sid, "g2", "a")
    :ok = Groups.add_member(tid, sid, "g1", "b")

    assert :ok = Groups.remove_participant(tid, sid, "a")
    assert Groups.members(tid, sid, "g1") == ["b"]
    assert Groups.members(tid, sid, "g2") == []
  end

  test "idempotent add/remove do not change membership", %{tid: tid, sid: sid} do
    :ok = Membership.join(tid, sid, "a", %{})
    :ok = Groups.create(tid, sid, "g")
    assert :ok = Groups.add_member(tid, sid, "g", "a")
    assert :ok = Groups.add_member(tid, sid, "g", "a")
    assert Groups.members(tid, sid, "g") == ["a"]
    assert :ok = Groups.remove_member(tid, sid, "g", "a")
    assert :ok = Groups.remove_member(tid, sid, "g", "a")
    assert Groups.members(tid, sid, "g") == []
  end
end
