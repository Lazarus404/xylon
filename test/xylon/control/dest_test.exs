defmodule Xylon.Control.DestTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Dest, Groups, Membership}

  setup do
    start_supervised!(Membership)
    start_supervised!(Groups)
    Membership.clear("t", "s")
    Groups.clear("t", "s")
    :ok
  end

  test "all stays :all" do
    assert {:ok, :all} = Dest.resolve("t", "s", "all", "a")
  end

  test "except drops actor" do
    :ok = Membership.join("t", "s", "a", %{role: "user"})
    :ok = Membership.join("t", "s", "b", %{role: "user"})
    assert {:ok, ids} = Dest.resolve("t", "s", "except", "a")
    assert Enum.sort(ids) == ["b"]
  end

  test "except with only actor is empty_dest" do
    :ok = Membership.join("t", "s", "a", %{})
    assert {:error, :empty_dest} = Dest.resolve("t", "s", :except, "a")
  end

  test "role filter" do
    :ok = Membership.join("t", "s", "a", %{role: "user"})
    :ok = Membership.join("t", "s", "m", %{role: "moderator"})
    assert {:ok, ids} = Dest.resolve("t", "s", %{"role" => "moderator"}, nil)
    assert Enum.sort(ids) == ["m"]
  end

  test "empty id list is empty_dest" do
    assert {:error, :empty_dest} = Dest.resolve("t", "s", [], nil)
  end

  test "group filter intersects membership" do
    :ok = Membership.join("t", "s", "a", %{})
    :ok = Membership.join("t", "s", "b", %{})
    :ok = Groups.create("t", "s", "g")
    :ok = Groups.add_member("t", "s", "g", "a")
    :ok = Groups.add_member("t", "s", "g", "b")
    Membership.leave("t", "s", "b")

    assert {:ok, ["a"]} = Dest.resolve("t", "s", %{"group" => "g"}, nil)
  end

  test "groups union" do
    :ok = Membership.join("t", "s", "a", %{})
    :ok = Membership.join("t", "s", "b", %{})
    :ok = Groups.create("t", "s", "g1")
    :ok = Groups.create("t", "s", "g2")
    :ok = Groups.add_member("t", "s", "g1", "a")
    :ok = Groups.add_member("t", "s", "g2", "b")

    assert {:ok, ids} = Dest.resolve("t", "s", %{"groups" => ["g1", "g2"]}, nil)
    assert Enum.sort(ids) == ["a", "b"]
  end

  test "mixing group and role is bad_dest" do
    assert {:error, :bad_dest} =
             Dest.resolve("t", "s", %{"group" => "g", "role" => "mod"}, nil)
  end
end
