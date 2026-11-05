defmodule Xylon.InvalidForwardPlanTest do
  use ExUnit.Case, async: false

  alias Xylon.{Forwarder, Participant, Session}

  defmodule BadPlanBackend do
    @moduledoc false
    @behaviour Xylon.Backend

    def id, do: :bad_forward_plan

    def init(_session, _opts), do: {:ok, %{}}

    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}
    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_reason, _state), do: :ok

    def forward_plan(_participant, _state), do: :bad
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(BadPlanBackend)
    :ok
  end

  test "attach_participant fails when forward_plan/2 returns a bad shape" do
    assert {:ok, session} = Session.create("t1", "bad-plan", :bad_forward_plan)
    assert {:ok, peer} = start_dummy_peer()

    p = %Participant{id: "p1", peer_ref: peer, role: :echo}

    assert {:error, {:invalid_forward_plan, :bad}} = Session.attach_participant(session, p)
    assert :error = Forwarder.plan_lookup(session, peer)
    refute Map.has_key?(:sys.get_state(session).participants, "p1")
  end

  defp start_dummy_peer do
    {:ok, spawn(fn -> Process.sleep(:infinity) end)}
  end
end
