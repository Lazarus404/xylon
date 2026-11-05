defmodule Xylon.SessionDatachannelOpenTest do
  use ExUnit.Case, async: false

  alias Xylon.{Participant, Session}

  defmodule OpenTrackingBackend do
    @behaviour Xylon.Backend

    def id, do: :open_track

    def init(_session, _opts), do: {:ok, %{opens: [], closed: [], sctp_down: []}}

    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}

    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}

    def handle_datachannel_open(participant, open, state) do
      {:ok, %{state | opens: [{participant.id, open} | state.opens]}}
    end

    def handle_datachannel_closed(participant, channel_ref, state) do
      {:ok, %{state | closed: [{participant.id, channel_ref} | state.closed]}}
    end

    def handle_sctp_disconnected(participant, state) do
      {:ok, %{state | sctp_down: [participant.id | state.sctp_down]}}
    end

    def terminate(_reason, _state), do: :ok
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(OpenTrackingBackend)
    :ok
  end

  test "datachannel open is forwarded to optional backend callback" do
    assert {:ok, session} = Session.create("t1", "dc-open", :open_track)
    peer = self()
    channel = make_ref()

    :sys.replace_state(session, fn state ->
      p = %Participant{id: "p1", peer_ref: peer, role: :publisher}
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    send(session, {:xgw, :datachannel, peer, %{ref: channel, label: "chat", id: 1}})
    Process.sleep(20)

    state = :sys.get_state(session)
    assert [{"p1", %{ref: ^channel, label: "chat", id: 1}}] = state.backend_state.opens
  end

  test "datachannel open before participant is bound is retried then forwarded" do
    assert {:ok, session} = Session.create("t1", "dc-open-early", :open_track)
    peer = self()
    channel = make_ref()

    send(session, {:xgw, :datachannel, peer, %{ref: channel, label: "chat", id: 1}})
    Process.sleep(30)
    state = :sys.get_state(session)
    assert state.backend_state.opens == []

    :sys.replace_state(session, fn state ->
      p = %Participant{id: "p1", peer_ref: peer, role: :publisher}
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    assert Enum.reduce_while(1..50, :timeout, fn _, _ ->
             Process.sleep(20)
             st = :sys.get_state(session)

             case st.backend_state.opens do
               [{"p1", %{ref: ^channel, label: "chat", id: 1}} | _] -> {:halt, :ok}
               _ -> {:cont, :timeout}
             end
           end) == :ok
  end

  test "datachannel closed is forwarded to optional backend callback" do
    assert {:ok, session} = Session.create("t1", "dc-closed", :open_track)
    peer = self()
    channel = make_ref()

    :sys.replace_state(session, fn state ->
      p = %Participant{id: "p1", peer_ref: peer, role: :publisher}
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    send(session, {:xgw, :datachannel_closed, peer, channel})
    Process.sleep(20)

    state = :sys.get_state(session)
    assert [{"p1", ^channel}] = state.backend_state.closed
  end

  test "sctp disconnected is forwarded to optional backend callback" do
    assert {:ok, session} = Session.create("t1", "dc-sctp-down", :open_track)
    peer = self()

    :sys.replace_state(session, fn state ->
      p = %Participant{id: "p1", peer_ref: peer, role: :publisher}
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    send(session, {:xgw, :sctp_disconnected, peer})
    Process.sleep(20)

    state = :sys.get_state(session)
    assert ["p1"] = state.backend_state.sctp_down
  end
end
