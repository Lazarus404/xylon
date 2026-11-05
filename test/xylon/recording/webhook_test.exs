defmodule Xylon.Recording.WebhookTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Webhooks.Delivery
  alias Xylon.Recording.Ctx

  defmodule CapturePlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pid = Application.get_env(:xylon, :recording_webhook_test_pid)

      if is_pid(pid) do
        send(pid, {:webhook, Plug.Conn.get_req_header(conn, "x-xylon-signature"), body})
      end

      send_resp(conn, 200, "ok")
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  defmodule ManifestHandler do
    @behaviour Xylon.Recording.Handler

    @impl true
    def on_start(%Ctx{}, _opts), do: {:ok, %{}}

    @impl true
    def on_stop(%Ctx{}, _state) do
      {:ok,
       %{
         artifacts: [
           %{
             "kind" => "audio",
             "publisher_id" => "alice",
             "mid" => "0",
             "codec" => "opus",
             "path_or_key" => "/tmp/rec/a.mjr",
             "bytes" => 12,
             "via" => nil,
             "edge_node" => "local"
           }
         ],
         counters: %{"packets" => 1, "bytes" => 12, "dropped_backpressure" => 0}
       }}
    end

    @impl true
    def on_publisher_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}

    @impl true
    def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
  end

  defmodule FailHandler do
    @behaviour Xylon.Recording.Handler

    @impl true
    def on_start(%Ctx{}, _opts), do: {:ok, %{}}

    @impl true
    def on_stop(%Ctx{}, _state), do: {:error, :finalize_failed}

    @impl true
    def on_publisher_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}

    @impl true
    def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
  end

  setup do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    :ok = Xylon.Recording.Registry.ensure_table!()
    {:ok, _} = Application.ensure_all_started(:inets)

    Application.put_env(:xylon, :recording_webhook_test_pid, self())
    port = 19_200 + rem(System.unique_integer([:positive]), 700)

    {:ok, bandit} =
      Bandit.start_link(plug: CapturePlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    url = "http://127.0.0.1:#{port}/"

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: url,
      webhook_secret: "rec-wh-secret"
    )

    on_exit(fn ->
      Process.exit(bandit, :normal)
      Application.delete_env(:xylon, :recording)
      Application.delete_env(:xylon, :recording_webhook_test_pid)
      Application.delete_env(:xylon, :control)
    end)

    :ok
  end

  defp await_type(type, timeout \\ 3_000) do
    receive do
      {:webhook, sig, body} ->
        payload = Jason.decode!(body)

        if payload["type"] == type do
          {sig, body, payload}
        else
          await_type(type, timeout)
        end
    after
      timeout -> flunk("timed out waiting for webhook type=#{inspect(type)}")
    end
  end

  test "stop emits recording.completed with segment fields and artifacts" do
    Application.put_env(:xylon, :recording, handler: ManifestHandler)
    sid = "wh-ok-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, started} = Xylon.Session.start_recording(session)
    assert {:ok, _} = Xylon.Session.stop_recording(session)

    {[sig], body, payload} = await_type("recording.completed")
    assert Delivery.valid_signature?(body, "rec-wh-secret", sig)
    assert payload["tenant_id"] == "t1"
    assert payload["session_id"] == sid
    assert payload["recording_id"] == started.recording_id
    assert payload["sequence"] == 1
    assert payload["preceded_by"] == nil
    assert payload["mode"] == "tracks"
    assert is_integer(payload["started_at"])
    assert is_integer(payload["ended_at"])
    assert payload["ended_at"] >= payload["started_at"]
    assert is_list(payload["artifacts"])
    assert hd(payload["artifacts"])["path_or_key"] == "/tmp/rec/a.mjr"
    assert is_map(payload["counters"])
  end

  test "stop emits recording.failed when on_stop errors" do
    Application.put_env(:xylon, :recording, handler: FailHandler)
    sid = "wh-fail-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, started} = Xylon.Session.start_recording(session)
    assert {:ok, _} = Xylon.Session.stop_recording(session)

    {_sig, _body, payload} = await_type("recording.failed")
    assert payload["recording_id"] == started.recording_id
    assert is_binary(payload["error"])
  end
end
