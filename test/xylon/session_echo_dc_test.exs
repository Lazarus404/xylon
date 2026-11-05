defmodule Xylon.SessionEchoDcTest do
  use ExUnit.Case, async: false

  alias Xylon.{Forwarder, Participant, Session}

  defmodule FakePeer do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])
    def drain(pid), do: GenServer.call(pid, :drain)

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call({:send_rtp, ssrc, packet}, _from, state) do
      {:reply, :ok, [{:send_rtp, ssrc, packet} | state]}
    end

    def handle_call({:send_datachannel, ref, data}, _from, state) do
      {:reply, :ok, [{:send_datachannel, ref, data} | state]}
    end

    def handle_call({:send_datachannel, ref, data, _type}, _from, state) do
      {:reply, :ok, [{:send_datachannel, ref, data} | state]}
    end

    def handle_call(:drain, _from, state), do: {:reply, Enum.reverse(state), []}

    @impl true
    def handle_cast({:send_datachannel, ref, data}, state) do
      {:noreply, [{:send_datachannel, ref, data} | state]}
    end

    def handle_cast({:send_datachannel, ref, data, _type}, state) do
      {:noreply, [{:send_datachannel, ref, data} | state]}
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "echo session sends datachannel back to same peer via Forwarder" do
    assert {:ok, session} = Session.create("t1", "echo-dc", :echo)
    assert {:ok, peer} = FakePeer.start_link()
    channel = make_ref()
    fwd = :sys.get_state(session).forwarder

    p = %Participant{id: "p1", peer_ref: peer, role: :echo}

    :sys.replace_state(session, fn state ->
      %{state | participants: Map.put(state.participants, "p1", p)}
    end)

    assert :ok = Forwarder.install_echo(fwd, p)

    send(fwd, {:xgw, :datachannel_message, peer, channel, "ping"})

    assert wait_drain(peer, [{:send_datachannel, channel, "ping"}])
  end

  defp wait_drain(peer, expected) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      case FakePeer.drain(peer) do
        ^expected ->
          {:halt, true}

        [] ->
          Process.sleep(10)
          {:cont, false}

        other ->
          flunk("unexpected: #{inspect(other)}")
      end
    end)
  end
end
