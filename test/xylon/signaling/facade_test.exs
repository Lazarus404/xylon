defmodule Xylon.Signaling.FacadeTest do
  use ExUnit.Case, async: false

  alias Xylon.Signaling

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "start_session registers under tenant and session id" do
    assert {:ok, pid} = Signaling.start_session("t1", "facade-s1", :echo)
    assert pid == Xylon.Session.whereis("t1", "facade-s1")
  end

  test "hangup stops the session" do
    assert {:ok, pid} = Signaling.start_session("t1", "facade-hang", :echo)
    assert :ok = Signaling.hangup("t1", "facade-hang")
    refute Process.alive?(pid)
    # Permanent restart would respawn under the same Registry name after EXIT.
    Process.sleep(50)
    assert is_nil(Xylon.Session.whereis("t1", "facade-hang"))
  end

  test "second start_session after hangup succeeds" do
    assert {:ok, _pid} = Signaling.start_session("t1", "facade-re", :echo)
    assert :ok = Signaling.hangup("t1", "facade-re")
    Process.sleep(50)
    assert {:ok, pid2} = Signaling.start_session("t1", "facade-re", :echo)
    assert pid2 == Xylon.Session.whereis("t1", "facade-re")
  end

  test "hangup missing session is not_found" do
    assert {:error, :not_found} = Signaling.hangup("t1", "missing")
  end

  test "apply_remote_offer missing session is not_found" do
    assert {:error, :not_found} = Signaling.apply_remote_offer("t1", "missing", "v=0\r\n")
  end
end
