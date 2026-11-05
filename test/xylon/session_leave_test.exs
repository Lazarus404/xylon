defmodule Xylon.SessionLeaveTest do
  use ExUnit.Case, async: false

  alias Xylon.{Participant, Session}

  defmodule FakePeer do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "leave_participant removes id and is idempotent" do
    assert {:ok, session} = Session.create("t1", "leave-1", :echo)
    assert {:ok, peer} = FakePeer.start_link()
    p = %Participant{id: "a", peer_ref: peer, role: :echo}

    :sys.replace_state(session, fn state ->
      %{state | participants: Map.put(state.participants, "a", p)}
    end)

    assert :ok = Session.leave_participant(session, "a")
    # Last participant: Session stops
    Process.sleep(50)
    assert is_nil(Session.whereis("t1", "leave-1"))
  end

  test "leave keeps session when other participants remain" do
    assert {:ok, session} = Session.create("t1", "leave-2", :echo)
    assert {:ok, peer_a} = FakePeer.start_link()
    assert {:ok, peer_b} = FakePeer.start_link()

    a = %Participant{id: "a", peer_ref: peer_a}
    b = %Participant{id: "b", peer_ref: peer_b}

    :sys.replace_state(session, fn state ->
      %{state | participants: %{"a" => a, "b" => b}}
    end)

    assert :ok = Session.leave_participant(session, "a")
    assert Process.alive?(session)
    state = :sys.get_state(session)
    assert Map.keys(state.participants) == ["b"]
    assert :ok = Session.leave_participant(session, "a")
  end

  test "Signaling.leave missing session is not_found" do
    assert {:error, :not_found} = Xylon.Signaling.leave("t1", "nope", "a")
  end
end
