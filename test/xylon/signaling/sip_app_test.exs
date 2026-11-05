defmodule Xylon.Signaling.SIPAppTest do
  use ExUnit.Case, async: false

  alias XSIP.Header.Type.{Contact, ContentType, From, To}
  alias XSIP.Message
  alias Xylon.Signaling.SIPApp
  alias Xylon.Signaling.SIP.Registrar

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
    Application.put_env(:xsip, :app, SIPApp)

    for mod <- [
          Xylon.Signaling.SIP.Registrar,
          Xylon.Signaling.SIP.ConnRegistry,
          Xylon.Signaling.SIP.SessionBind
        ] do
      case Process.whereis(mod) do
        nil -> start_supervised!(mod)
        _pid -> :ok
      end
    end

    :ok
  end

  test "REGISTER stores AOR contacts" do
    msg = %Message{
      type: :request,
      method: "REGISTER",
      headers: %{
        "to" => [%To{uri: "sip:alice@lab", tag: nil, params: %{}}],
        "from" => [%From{uri: "sip:alice@lab", tag: "t", params: %{}}],
        "contact" => [%Contact{uri: "sip:alice@127.0.0.1", params: %{}}],
        "expires" => ["3600"]
      },
      body: ""
    }

    assert :ok = SIPApp.handle_register(msg, %{})
    assert [%Contact{uri: "sip:alice@127.0.0.1"}] = Registrar.get("sip:alice@lab")
  end

  test "INVITE with SDP accepts and returns fingerprint answer" do
    msg = invite_message(@offer)

    assert {:accept, answer} = SIPApp.handle_invite(msg, self(), %{conn: "ws-test"})
    assert is_binary(answer)
    assert answer =~ "a=fingerprint:sha-256"
    assert Xylon.Session.whereis("lab", "echo")
  end

  test "second INVITE after hangup path replaces session" do
    msg = invite_message(@offer)
    assert {:accept, _} = SIPApp.handle_invite(msg, self(), %{conn: "ws-a"})
    Process.sleep(50)
    assert {:accept, answer} = SIPApp.handle_invite(msg, self(), %{conn: "ws-b"})
    assert is_binary(answer)
    assert answer =~ "a=fingerprint:sha-256"
  end

  test "BYE hangup stops the lab session" do
    msg = invite_message(@offer)
    assert {:accept, _} = SIPApp.handle_invite(msg, self(), %{conn: "ws-bye"})
    assert pid = Xylon.Session.whereis("lab", "echo")

    bye = %Message{
      type: :request,
      method: "BYE",
      headers: %{
        "to" => [%To{uri: "sip:echo@lab", tag: "z", params: %{}}],
        "from" => [%From{uri: "sip:bob@lab", tag: "t", params: %{}}]
      },
      body: ""
    }

    assert :ok = SIPApp.handle_in_dialog(bye, self(), %{conn: "ws-bye"})
    Process.sleep(50)
    refute Process.alive?(pid)
    assert is_nil(Xylon.Session.whereis("lab", "echo"))
  end

  test "INVITE without SDP is rejected" do
    msg = %Message{
      type: :request,
      method: "INVITE",
      headers: %{
        "to" => [%To{uri: "sip:echo@lab", tag: nil, params: %{}}],
        "from" => [%From{uri: "sip:bob@lab", tag: "t", params: %{}}]
      },
      body: ""
    }

    assert {:reject, 415, _} = SIPApp.handle_invite(msg, self(), %{})
  end

  defp invite_message(sdp) do
    %Message{
      type: :request,
      method: "INVITE",
      headers: %{
        "to" => [%To{uri: "sip:echo@lab", tag: nil, params: %{}}],
        "from" => [%From{uri: "sip:bob@lab", tag: "t", params: %{}}],
        "content-type" => [
          %ContentType{type: "application", subtype: "sdp", params: %{}}
        ]
      },
      body: sdp
    }
  end
end
