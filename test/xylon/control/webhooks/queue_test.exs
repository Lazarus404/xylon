defmodule Xylon.Control.Webhooks.QueueTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Webhooks
  alias Xylon.Control.Webhooks.Queue

  defmodule FailThenOkPlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      case Application.get_env(:xylon, :webhook_fail_mode, :fail) do
        :fail -> send_resp(conn, 500, "no")
        :ok -> send_resp(conn, 200, "ok")
      end
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    path = Path.join(System.tmp_dir!(), "xylon-dlq-#{System.unique_integer([:positive])}.dets")
    File.rm(path)

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: "http://127.0.0.1:1/",
      webhook_secret: "s3cret",
      webhook_dlq_path: path,
      webhook_dlq_max: 5,
      webhook_dlq_interval_ms: 60_000,
      webhook_dlq_max_attempts: 20
    )

    pid = start_supervised!({Queue, []})

    on_exit(fn ->
      Application.delete_env(:xylon, :control)
      Application.delete_env(:xylon, :webhook_fail_mode)
      File.rm(path)
    end)

    %{path: path, queue: pid}
  end

  test "enqueue_after_failure persists and list returns it" do
    assert :ok = Queue.enqueue_after_failure("participant.joined", %{"tenant_id" => "t1"})
    assert [%{type: "participant.joined", payload: %{"tenant_id" => "t1"}}] = Queue.list()
    assert {1, 5} = Queue.stats()
  end

  test "cap drops oldest when over webhook_dlq_max" do
    for i <- 1..6 do
      assert :ok =
               Queue.enqueue_after_failure("inject.accepted", %{"n" => i, "tenant_id" => "t"})

      # Distinct enqueued_at for stable oldest eviction.
      Process.sleep(2)
    end

    assert {5, 5} = Queue.stats()
    ids_payload = Enum.map(Queue.list(), & &1.payload["n"])
    refute 1 in ids_payload
    assert Enum.sort(ids_payload) == [2, 3, 4, 5, 6]
  end

  test "rows survive Queue restart on same path", %{path: path} do
    assert :ok = Queue.enqueue_after_failure("session.closed", %{"session_id" => "s1"})
    assert [_] = Queue.list()

    :ok = stop_supervised(Queue)
    # DETS file remains
    assert File.exists?(path)

    start_supervised!({Queue, []})
    assert [%{type: "session.closed", payload: %{"session_id" => "s1"}}] = Queue.list()
  end

  test "live deliver failure enqueues; drain delivers when endpoint recovers" do
    port = 19_100 + rem(System.unique_integer([:positive]), 800)
    Application.put_env(:xylon, :webhook_fail_mode, :fail)

    {:ok, bandit} =
      Bandit.start_link(plug: FailThenOkPlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    on_exit(fn -> Process.exit(bandit, :normal) end)

    control = Application.get_env(:xylon, :control)
    Application.put_env(:xylon, :control, Keyword.put(control, :webhook_url, "http://127.0.0.1:#{port}/"))

    assert :ok = Webhooks.emit("quota.exceeded", %{"tenant_id" => "t1", "kind" => "inject"})

    assert_receive_list(fn -> length(Queue.list()) == 1 end, 3_000)

    Application.put_env(:xylon, :webhook_fail_mode, :ok)
    assert :ok = Queue.drain()
    assert [] = Queue.list()
  end

  test "emit returns :ok without blocking" do
    assert :ok = Webhooks.emit("participant.joined", %{"tenant_id" => "t"})
  end

  test "flush! clears the queue" do
    assert :ok = Queue.enqueue_after_failure("participant.left", %{"tenant_id" => "t"})
    assert [_] = Queue.list()
    assert :ok = Queue.flush!()
    assert [] = Queue.list()
  end

  defp assert_receive_list(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        Process.sleep(50)
        if System.monotonic_time(:millisecond) > deadline, do: flunk("timeout waiting for DLQ"), else: :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end
end
