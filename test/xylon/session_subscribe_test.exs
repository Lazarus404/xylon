defmodule Xylon.SessionSubscribeTest do
  use ExUnit.Case, async: false

  alias Xylon.Session

  defmodule SubBackend do
    @behaviour Xylon.Backend

    def id, do: :sub_track

    def init(_session, _opts), do: {:ok, %{subs: [], unsubs: [], updates: [], alls: []}}

    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}
    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_r, _s), do: :ok

    def subscribe(sub, pub, mid, opts, state) do
      {:ok, %{state | subs: [{sub, pub, mid, opts} | state.subs]}}
    end

    def subscribe_all(sub, pub, opts, state) do
      {:ok, %{state | alls: [{sub, pub, opts} | state.alls]}}
    end

    def unsubscribe(sub, pub, mid, opts, state) do
      {:ok, %{state | unsubs: [{sub, pub, mid, opts} | state.unsubs]}}
    end

    def update_subscriptions(sub, streams, opts, state) do
      {:ok, %{state | updates: [{sub, streams, opts} | state.updates]}}
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(SubBackend)
    :ok
  end

  test "Session.subscribe delegates to Backend with forwarder opt" do
    assert {:ok, session} = Session.create("t1", "sub-api", :sub_track)
    assert :ok = Session.subscribe(session, "b", "a", "0")

    state = :sys.get_state(session)
    assert [{"b", "a", "0", opts}] = state.backend_state.subs
    assert Keyword.get(opts, :forwarder) == state.forwarder
  end

  test "Session.subscribe_all delegates to Backend" do
    assert {:ok, session} = Session.create("t1", "sub-all-api", :sub_track)
    assert :ok = Session.subscribe_all(session, "b", "a")

    state = :sys.get_state(session)
    assert [{"b", "a", opts}] = state.backend_state.alls
    assert Keyword.get(opts, :forwarder) == state.forwarder
  end

  test "Session.unsubscribe delegates to Backend" do
    assert {:ok, session} = Session.create("t1", "unsub-api", :sub_track)
    assert :ok = Session.unsubscribe(session, "b", "a", "1")

    state = :sys.get_state(session)
    assert [{"b", "a", "1", _opts}] = state.backend_state.unsubs
  end

  test "Session.update_subscriptions delegates to Backend" do
    assert {:ok, session} = Session.create("t1", "update-api", :sub_track)
    streams = [%{publisher_id: "a", mid: "0"}]

    assert :ok = Session.update_subscriptions(session, "b", streams)

    state = :sys.get_state(session)
    assert [{"b", ^streams, opts}] = state.backend_state.updates
    assert Keyword.get(opts, :forwarder) == state.forwarder
  end

  test "echo Backend returns not_supported" do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    assert {:ok, session} = Session.create("t1", "echo-sub", :echo)
    assert {:error, :not_supported} = Session.subscribe(session, "b", "a", "0")
  end
end
