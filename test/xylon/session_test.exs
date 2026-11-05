defmodule Xylon.SessionTest do
  use ExUnit.Case, async: false

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "create registers under tenant and session id" do
    assert {:ok, pid} = Xylon.Session.create("t1", "s1", :echo)
    assert pid == Xylon.Session.whereis("t1", "s1")
    assert is_nil(Xylon.Session.whereis("t2", "s1"))
  end

  test "create fails for unattached module" do
    assert {:error, :not_attached} = Xylon.Session.create("t1", "s2", :conference)
  end
end
