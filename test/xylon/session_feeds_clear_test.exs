defmodule Xylon.SessionFeedsClearTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Feeds
  alias Xylon.Session

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    start_supervised!(Feeds)
    :ok
  end

  test "session terminate clears Feeds for the session" do
    assert {:ok, pid} = Session.create("t1", "feeds-clear", :echo)
    assert :ok = Feeds.put("t1", "feeds-clear", "ghost", %{kinds: [:audio]})
    assert [_] = Feeds.list("t1", "feeds-clear")

    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    assert [] = Feeds.list("t1", "feeds-clear")
  end
end
