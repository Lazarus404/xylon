defmodule Xylon.Forwarder.ArrivalUsTest do
  use ExUnit.Case, async: false

  alias Xylon.Forwarder
  alias Xylon.Participant
  alias XMediaLib.Rtp

  defmodule ArrivalBackend do
    @moduledoc false

    def init(_session, opts) do
      {:ok, %{notify: Keyword.fetch!(opts, :notify)}}
    end

    def handle_rtp(_participant, _rtp, state) do
      send(state.notify, {:arrival_seen, Process.get(:xylon_rtp_arrival_us)})
      {:ok, state}
    end

    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_reason, _state), do: :ok
  end

  setup do
    Forwarder.ensure_table!()
    :ok
  end

  test "Forwarder puts meta arrival_us for Backend.handle_rtp" do
    {:ok, fwd} =
      Forwarder.start_link(
        session: self(),
        backend: ArrivalBackend,
        session_id: "arrival-us",
        tenant_id: "t",
        send_workers: 0,
        notify: self()
      )

    on_exit(fn -> if Process.alive?(fwd), do: GenServer.stop(fwd) end)

    peer = self()
    participant = %Participant{id: "p1", peer_ref: peer}
    assert :ok = Forwarder.put_plan(fwd, peer, %{mode: :sfu, participant: participant})

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: <<"v">>
    }

    send(fwd, {:xgw, :rtp, peer, rtp, %{arrival_us: 99_001}})
    assert_receive {:arrival_seen, 99_001}, 1_000

    send(fwd, {:xgw, :rtp, peer, rtp, %{}})
    assert_receive {:arrival_seen, nil}, 1_000
  end
end
