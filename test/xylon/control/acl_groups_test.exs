defmodule Xylon.Control.AclGroupsTest do
  use ExUnit.Case, async: true

  alias Xylon.Control.Acl
  alias Xylon.Control.Context

  defp ctx(caps),
    do: %Context{tenant_id: "t", session_id: "s", participant_id: "a", capabilities: caps}

  test "allow_groups_send_dest? requires every scoped group" do
    dest = %{"groups" => ["g1", "g2"]}

    assert Acl.allow_groups_send_dest?(ctx([]), dest)
    assert Acl.allow_groups_send_dest?(ctx(["groups:send"]), dest)
    refute Acl.allow_groups_send_dest?(ctx(["groups:send:g1"]), dest)
    assert Acl.allow_groups_send_dest?(ctx(["groups:send:g1", "groups:send:g2"]), dest)
  end

  test "group_dest_ids collects group and groups" do
    assert Acl.group_dest_ids(%{"group" => "a", "groups" => ["b", "c"]}) == ["a", "b", "c"]
    assert Acl.group_dest_ids(%{group: "x"}) == ["x"]
  end
end
