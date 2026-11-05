defmodule Xylon.Trunk.ManagerTest do
  use ExUnit.Case, async: false

  alias Xylon.Participant
  alias Xylon.Session
  alias Xylon.Trunk.Manager

  @master_key <<0xE1F97A0D3E018BE0D64FA32C06DE4139::size(128)>>
  @master_salt <<0x0EC675AD498AFEEBB6960B3AABE6::size(112)>>

  setup do
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    sid = "trunk-mgr-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :echo)
    on_exit(fn -> Session.hangup(session) end)
    %{session: session, sid: sid}
  end

  test "connect returns trunk participant and installs into session", %{session: session} do
    assert {:ok, %Participant{id: "trunk1", role: :trunk, peer_ref: pipe}} =
             Manager.connect(session,
               id: "trunk1",
               master_key: @master_key,
               master_salt: @master_salt
             )

    assert is_pid(pipe)
    state = :sys.get_state(session)
    assert %Participant{role: :trunk, peer_ref: ^pipe} = state.participants["trunk1"]

    assert :ok = Manager.disconnect(session, "trunk1")
    state2 = :sys.get_state(session)
    refute Map.has_key?(state2.participants, "trunk1")
  end

  test "connect_pair links two local pipes over UDP", %{session: session} do
    sid_b = "trunk-mgr-b-#{System.unique_integer([:positive])}"
    assert {:ok, session_b} = Session.create("t1", sid_b, :echo)
    on_exit(fn -> Session.hangup(session_b) end)

    assert {:ok, %{a: pa, b: pb}} =
             Manager.connect_pair(session, session_b,
               id_a: "trunk_ab",
               id_b: "trunk_ba",
               master_key: @master_key,
               master_salt: @master_salt
             )

    assert pa.role == :trunk
    assert pb.role == :trunk
    assert is_pid(pa.peer_ref)
    assert is_pid(pb.peer_ref)
  end
end
