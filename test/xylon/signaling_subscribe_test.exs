defmodule Xylon.SignalingSubscribeTest do
  use ExUnit.Case, async: false

  alias Xylon.Signaling

  defmodule SubBackend do
    @behaviour Xylon.Backend

    def id, do: :sig_sub

    def init(_session, _opts), do: {:ok, %{subs: [], layers: []}}
    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}
    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_r, _s), do: :ok

    def subscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: [{sub, pub, mid} | state.subs]}}
    end

    def unsubscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: List.delete(state.subs, {sub, pub, mid})}}
    end

    def set_substream(sub, pub, mid, opts, state) do
      {:ok, %{state | layers: [{sub, pub, mid, opts} | state.layers]}}
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(SubBackend)
    :ok
  end

  test "Signaling.subscribe and unsubscribe" do
    assert {:ok, session} = Signaling.start_session("t1", "sig-sub", :sig_sub)
    assert :ok = Signaling.subscribe("t1", "sig-sub", "b", "a", "0")
    assert [{"b", "a", "0"}] = :sys.get_state(session).backend_state.subs
    assert :ok = Signaling.unsubscribe("t1", "sig-sub", "b", "a", "0")
    assert [] = :sys.get_state(session).backend_state.subs
  end

  test "Signaling.set_substream passes opts" do
    assert {:ok, session} = Signaling.start_session("t1", "sig-layer", :sig_sub)

    assert :ok =
             Signaling.set_substream("t1", "sig-layer", "b", "a", "1", substream: 1, rid: "h")

    assert [{"b", "a", "1", opts}] = :sys.get_state(session).backend_state.layers
    assert Keyword.get(opts, :substream) == 1
    assert Keyword.get(opts, :rid) == "h"
    assert is_pid(Keyword.get(opts, :forwarder))
  end

  test "Signaling.subscribe not_found" do
    assert {:error, :not_found} = Signaling.subscribe("t1", "missing", "b", "a", "0")
  end
end
