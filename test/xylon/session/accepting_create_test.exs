defmodule Xylon.Session.AcceptingCreateTest do
  use ExUnit.Case, async: false

  alias Xylon.Cluster.Accepting

  setup do
    Xylon.Catalogue.reset!()
    Accepting.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    on_exit(fn -> Accepting.reset!() end)
    :ok
  end

  test "create rejects new session when not accepting" do
    assert :ok = Accepting.set(false)
    sid = "drain-create-#{System.unique_integer([:positive])}"
    assert {:error, :not_accepting} = Xylon.Session.create("t1", sid, :echo)
  end

  test "create succeeds when accepting" do
    sid = "ok-create-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Xylon.Session.create("t1", sid, :echo)
    GenServer.stop(pid)
  end

  test "existing session stays usable after drain; new create fails" do
    sid = "keep-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Xylon.Session.create("t1", sid, :echo)
    assert is_pid(Xylon.Session.whereis("t1", sid))

    assert :ok = Accepting.set(false)
    assert Xylon.Session.whereis("t1", sid) == pid
    assert {:error, :already_exists} = Xylon.Session.create("t1", sid, :echo)
    assert {:error, :not_accepting} =
             Xylon.Session.create("t1", "new-#{System.unique_integer([:positive])}", :echo)

    GenServer.stop(pid)
  end
end
