defmodule Xylon.SessionOfferTest do
  use ExUnit.Case, async: false

  alias Xylon.Session

  @offer """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=ice-ufrag:chromeUfrag
  a=ice-pwd:chromepasswordchromepass
  a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
  a=setup:actpass
  a=mid:0
  a=rtcp-mux
  a=sendrecv
  a=rtpmap:111 opus/48000/2
  """
  |> String.replace("\n", "\r\n")

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok
  end

  test "apply_offer returns answer with fingerprint and starts peer" do
    assert {:ok, pid} = Session.create("t1", "offer1", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @offer)
    assert is_binary(answer)
    assert answer =~ "a=fingerprint:sha-256"
    assert answer =~ "a=setup:"

    participants = :sys.get_state(pid).participants
    assert %{peer_ref: peer} = Map.fetch!(participants, "p1")
    assert is_pid(peer)
    assert Process.alive?(peer)
  end

  @av_offer """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0 1
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=ice-ufrag:chromeUfrag
  a=ice-pwd:chromepasswordchromepass
  a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
  a=setup:actpass
  a=mid:0
  a=rtcp-mux
  a=sendrecv
  a=rtpmap:111 opus/48000/2
  m=video 9 UDP/TLS/RTP/SAVPF 96
  c=IN IP4 0.0.0.0
  a=ice-ufrag:chromeUfrag
  a=ice-pwd:chromepasswordchromepass
  a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
  a=setup:actpass
  a=mid:1
  a=rtcp-mux
  a=sendrecv
  a=rtpmap:96 VP8/90000
  """
  |> String.replace("\n", "\r\n")

  test "apply_offer answers audio and video m-lines" do
    assert {:ok, pid} = Session.create("t1", "offer-av", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @av_offer)
    assert answer =~ "m=audio"
    assert answer =~ "m=video"
    assert answer =~ "VP8" or answer =~ "vp8"
  end

  # XGW Descriptions picks transport from the first DTLS m-line (RTP or SCTP).
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

  test "apply_offer answers datachannel-only offers" do
    assert {:ok, pid} = Session.create("t1", "offer-dc", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @dc_only_offer)
    assert answer =~ "m=application"
    assert answer =~ "sctp-port"
    assert answer =~ "a=fingerprint:sha-256"
  end

  test "ice advertised_ip pins answer to a single host candidate address" do
    prev = Application.get_env(:xylon, :ice)
    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:xylon, :ice)
      else
        Application.put_env(:xylon, :ice, prev)
      end
    end)

    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})

    assert {:ok, pid} = Session.create("t1", "offer-ice-pin", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @dc_only_offer)

    candidates =
      answer
      |> String.split("\r\n")
      |> Enum.filter(&String.starts_with?(&1, "a=candidate:"))

    assert candidates != []
    assert Enum.all?(candidates, &String.contains?(&1, " 127.0.0.1 "))
    refute Enum.any?(candidates, &String.match?(&1, ~r/ 192\.168\.\d+\.\d+ /))
  end

  test "second apply_offer with different participant_id succeeds" do
    assert {:ok, pid} = Session.create("t1", "offer-multi", :echo)
    assert {:ok, _a1} = Session.apply_offer(pid, @offer, participant_id: "a")
    assert {:ok, _a2} = Session.apply_offer(pid, @offer, participant_id: "b")

    state = :sys.get_state(pid)
    assert Map.has_key?(state.participants, "a")
    assert Map.has_key?(state.participants, "b")

    la = Map.fetch!(state.participants, "a").listener
    lb = Map.fetch!(state.participants, "b").listener
    assert is_pid(la)
    assert is_pid(lb)
    assert la != lb
  end

  test "duplicate participant_id is rejected" do
    assert {:ok, pid} = Session.create("t1", "offer-dup", :echo)
    assert {:ok, _} = Session.apply_offer(pid, @offer, participant_id: "a")
    assert {:error, :participant_exists} = Session.apply_offer(pid, @offer, participant_id: "a")
  end

  test "closing one peer leaves the other participant" do
    assert {:ok, pid} = Session.create("t1", "offer-leave", :echo)
    assert {:ok, _} = Session.apply_offer(pid, @offer, participant_id: "a")
    assert {:ok, _} = Session.apply_offer(pid, @offer, participant_id: "b")

    state = :sys.get_state(pid)
    peer_a = Map.fetch!(state.participants, "a").peer_ref
    listener_a = Map.fetch!(state.participants, "a").listener
    ref = Process.monitor(peer_a)

    _ = XGW.Peer.close(peer_a)

    assert_receive {:DOWN, ^ref, :process, ^peer_a, _}, 2_000

    # Wait for Session :closed handling + deferred Listener stop
    Enum.reduce_while(1..40, :wait, fn _, _ ->
      state2 = :sys.get_state(pid)

      if Map.has_key?(state2.participants, "a") do
        Process.sleep(25)
        {:cont, :wait}
      else
        {:halt, :done}
      end
    end)

    assert Process.alive?(pid)
    state2 = :sys.get_state(pid)
    refute Map.has_key?(state2.participants, "a")
    assert Map.has_key?(state2.participants, "b")

    Enum.reduce_while(1..40, :wait, fn _, _ ->
      if Process.alive?(listener_a) do
        Process.sleep(25)
        {:cont, :wait}
      else
        {:halt, :done}
      end
    end)

    refute Process.alive?(listener_a)
  end

  test "apply_offer ice_mode :full omits ice-lite and starts full Peer" do
    assert {:ok, pid} = Session.create("t1", "offer-full", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @dc_only_offer, ice_mode: :full)

    refute answer =~ "a=ice-lite"
    assert answer =~ "a=candidate:"
    assert answer =~ "127.0.0.1"

    peer = Map.fetch!(:sys.get_state(pid).participants, "p1").peer_ref
    assert :sys.get_state(peer).ice_lite == false
  end

  test "apply_offer default stays ICE-lite" do
    assert {:ok, pid} = Session.create("t1", "offer-lite", :echo)
    assert {:ok, answer} = Session.apply_offer(pid, @dc_only_offer)

    assert answer =~ "a=ice-lite"
    peer = Map.fetch!(:sys.get_state(pid).participants, "p1").peer_ref
    assert :sys.get_state(peer).ice_lite == true
  end
end
