defmodule Xylon.Control.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Webhooks.Delivery
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

  defmodule CapturePlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pid = Application.get_env(:xylon, :lifecycle_webhook_test_pid)

      if is_pid(pid) do
        send(pid, {:webhook, body})
      end

      send_resp(conn, 200, "ok")
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    start_supervised!(Xylon.Control.Membership)
    {:ok, _} = Application.ensure_all_started(:inets)

    Application.put_env(:xylon, :lifecycle_webhook_test_pid, self())
    port = 19_300 + rem(System.unique_integer([:positive]), 600)

    {:ok, bandit} =
      Bandit.start_link(plug: CapturePlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: "http://127.0.0.1:#{port}/",
      webhook_secret: "life-secret"
    )

    on_exit(fn ->
      Process.exit(bandit, :normal)
      Application.delete_env(:xylon, :lifecycle_webhook_test_pid)
      Application.delete_env(:xylon, :control)
    end)

    :ok
  end

  defp await_type(type, timeout \\ 3_000) do
    receive do
      {:webhook, body} ->
        payload = Jason.decode!(body)

        if payload["type"] == type do
          payload
        else
          await_type(type, timeout)
        end
    after
      timeout -> flunk("timed out waiting for webhook type=#{inspect(type)}")
    end
  end

  test "create join leave emit session.created participant.joined/left session.closed with node region" do
    sid = "life-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :echo)

    created = await_type("session.created")
    assert created["tenant_id"] == "t1"
    assert created["session_id"] == sid
    assert is_binary(created["node"]) and created["node"] != ""
    assert is_binary(created["region"]) and created["region"] != ""

    assert {:ok, _answer} = Session.apply_offer(session, @offer, participant_id: "alice")

    joined = await_type("participant.joined")
    assert joined["participant_id"] == "alice"
    assert joined["session_id"] == sid
    assert joined["node"] == created["node"]
    assert joined["region"] == created["region"]

    assert :ok = Session.leave_participant(session, "alice")

    left = await_type("participant.left")
    assert left["participant_id"] == "alice"
    assert left["node"] == created["node"]

    closed = await_type("session.closed")
    assert closed["session_id"] == sid
    assert closed["node"] == created["node"]
    assert closed["region"] == created["region"]

    refute_receive {:webhook, _}, 200
  end

  test "local attach emits participant.joined; remote trunk attach does not" do
    sid = "life-attach-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Session.create("t1", sid, :echo)
    _ = await_type("session.created")

    local = %Xylon.Participant{id: "local-p", role: :echo, meta: %{}}
    assert :ok = Session.attach_participant(session, local)
    joined = await_type("participant.joined")
    assert joined["participant_id"] == "local-p"

    remote = %Xylon.Participant{
      id: "remote-p",
      role: :trunk,
      meta: %{remote: true, from_edge: :"edge@127.0.0.1"}
    }

    assert :ok = Session.attach_participant(session, remote)
    refute_receive {:webhook, _}, 300

    assert :ok = Session.leave_participant(session, "remote-p", stop_if_empty: false)
    refute_receive {:webhook, _}, 300

    assert :ok = Session.leave_participant(session, "local-p")
    left = await_type("participant.left")
    assert left["participant_id"] == "local-p"
    _ = await_type("session.closed")
  end

  test "Delivery sign still verifies lifecycle bodies" do
    body = Jason.encode!(%{"type" => "session.created", "tenant_id" => "t"})
    sig = Delivery.sign(body, "life-secret")
    assert Delivery.valid_signature?(body, "life-secret", sig)
  end
end
