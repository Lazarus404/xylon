defmodule Xylon.SessionIcePushTest do
  use ExUnit.Case, async: false

  alias Xylon.Session

  @dc_only_offer """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0
  m=application 9 UDP/DTLS/SCTP webrtc-datachannel
  c=IN IP4 0.0.0.0
  a=ice-ufrag:chromeUfrag
  a=ice-pwd:chromepasswordchromepass
  a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
  a=setup:actpass
  a=mid:0
  a=sctp-port:5000
  a=max-message-size:262144
  """
  |> String.replace("\n", "\r\n")

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "bind_signaling flushes buffered ice_complete from full Peer" do
    assert {:ok, pid} = Session.create("t1", "ice-push", :echo)
    assert {:ok, _answer} = Session.apply_offer(pid, @dc_only_offer, ice_mode: :full)

    # Full Peer without STUN emits local_candidates_complete quickly; may buffer.
    Process.sleep(50)
    assert :ok = Session.bind_signaling(pid, "p1", self())

    assert_receive {:xylon_control_ice, %{type: :ice_complete}}, 1_000
  end

  test "bind_signaling forwards injected local_candidate" do
    assert {:ok, pid} = Session.create("t1", "ice-cand", :echo)
    assert {:ok, _} = Session.apply_offer(pid, @dc_only_offer, ice_mode: :full)
    assert :ok = Session.bind_signaling(pid, "p1", self())

    peer = Map.fetch!(:sys.get_state(pid).participants, "p1").peer_ref

    send(
      pid,
      {:xgw, :local_candidate, peer,
       %{candidate: "candidate:1 1 UDP 1 203.0.113.1 9 typ srflx", mid: "0"}}
    )

    assert_receive {:xylon_control_ice,
                    %{
                      type: :ice,
                      candidate: "candidate:1 1 UDP 1 203.0.113.1 9 typ srflx",
                      sdpMid: "0"
                    }},
                   500
  end
end
