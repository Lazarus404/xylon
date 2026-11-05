defmodule Xylon.Recording.AggregatorTest do
  use ExUnit.Case, async: false

  alias Xylon.Recording.Aggregator

  defmodule CapturePlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pid = Application.get_env(:xylon, :recording_agg_webhook_test_pid)

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
    {:ok, _} = Application.ensure_all_started(:xylon)
    Aggregator.reset!()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    {:ok, _pid} =
      Bandit.start_link(plug: CapturePlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    url = "http://127.0.0.1:#{port}/"
    Application.put_env(:xylon, :recording_agg_webhook_test_pid, self())

    prev_webhooks = Application.get_env(:xylon, :control, [])

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: url,
      webhook_secret: "agg-test"
    )

    on_exit(fn ->
      Application.put_env(:xylon, :control, prev_webhooks)
      Application.delete_env(:xylon, :recording_agg_webhook_test_pid)
      Aggregator.reset!()
    end)

    :ok
  end

  test "emits once after all expected edges report" do
    rid = "rec-agg-#{System.unique_integer([:positive])}"

    assert :ok =
             Aggregator.begin_segment(%{
               recording_id: rid,
               tenant_id: "t1",
               session_id: "s1",
               sequence: 1,
               preceded_by: nil,
               mode: "tracks",
               started_at: 1000,
               expected_edges: ["edge_a@127.0.0.1", "edge_b@127.0.0.1"]
             })

    task =
      Task.async(fn ->
        Aggregator.await_or_flush(rid, 5_000)
      end)

    assert :ok =
             Aggregator.report_edge(rid, %{
               edge_node: "edge_a@127.0.0.1",
               artifacts: [
                 %{
                   "kind" => "audio",
                   "publisher_id" => "alice",
                   "mid" => "0",
                   "codec" => "opus",
                   "path_or_key" => "/tmp/a.mjr",
                   "bytes" => 1,
                   "via" => nil,
                   "edge_node" => "edge_a@127.0.0.1"
                 }
               ],
               counters: %{"packets" => 1}
             })

    refute_receive {:webhook, _}, 100

    assert :ok =
             Aggregator.report_edge(rid, %{
               edge_node: "edge_b@127.0.0.1",
               artifacts: [
                 %{
                   "kind" => "audio",
                   "publisher_id" => "bob",
                   "mid" => "0",
                   "codec" => "opus",
                   "path_or_key" => "/tmp/b.mjr",
                   "bytes" => 2,
                   "via" => "trunk",
                   "edge_node" => "edge_b@127.0.0.1"
                 }
               ],
               counters: %{"packets" => 2}
             })

    assert :ok = Task.await(task)

    assert_receive {:webhook, body}, 2_000
    payload = Jason.decode!(body)
    assert payload["type"] == "recording.completed"
    assert payload["recording_id"] == rid
    edges = Enum.map(payload["artifacts"], & &1["edge_node"]) |> Enum.sort()
    assert edges == ["edge_a@127.0.0.1", "edge_b@127.0.0.1"]
    assert payload["counters"]["edges_missing"] == 0
    assert payload["counters"]["packets"] == 3

    refute_receive {:webhook, _}, 200
  end

  test "force_flush emits with edges_missing" do
    rid = "rec-flush-#{System.unique_integer([:positive])}"

    assert :ok =
             Aggregator.begin_segment(%{
               recording_id: rid,
               tenant_id: "t1",
               session_id: "s1",
               sequence: 1,
               preceded_by: nil,
               mode: "tracks",
               started_at: 1000,
               expected_edges: ["edge_a@127.0.0.1", "edge_b@127.0.0.1"]
             })

    assert :ok =
             Aggregator.report_edge(rid, %{
               edge_node: "edge_a@127.0.0.1",
               artifacts: [],
               counters: %{},
               had_local_publishers: false
             })

    assert :ok = Aggregator.force_flush(rid)

    assert_receive {:webhook, body}, 2_000
    payload = Jason.decode!(body)
    assert payload["type"] == "recording.completed"
    assert payload["counters"]["edges_missing"] == 1
    assert payload["counters"]["edges_idle"] == 1
  end

  test "idle empty report unblocks await; add_expected_edges for late joiner" do
    rid = "rec-idle-#{System.unique_integer([:positive])}"

    assert :ok =
             Aggregator.begin_segment(%{
               recording_id: rid,
               tenant_id: "t1",
               session_id: "s1",
               sequence: 1,
               preceded_by: nil,
               mode: "tracks",
               started_at: 1000,
               expected_edges: ["edge_a@127.0.0.1"]
             })

    assert :ok = Aggregator.add_expected_edges(rid, ["edge_b@127.0.0.1"])

    task = Task.async(fn -> Aggregator.await_or_flush(rid, 5_000) end)

    assert :ok =
             Aggregator.report_edge(rid, %{
               edge_node: "edge_a@127.0.0.1",
               artifacts: [
                 %{
                   "kind" => "audio",
                   "publisher_id" => "alice",
                   "mid" => "0",
                   "codec" => "opus",
                   "path_or_key" => "/tmp/a.mjr",
                   "bytes" => 1,
                   "edge_node" => "edge_a@127.0.0.1"
                 }
               ],
               counters: %{"packets" => 1},
               had_local_publishers: true
             })

    assert :ok =
             Aggregator.report_edge(rid, %{
               edge_node: "edge_b@127.0.0.1",
               artifacts: [],
               counters: %{},
               had_local_publishers: false
             })

    assert :ok = Task.await(task)

    assert_receive {:webhook, body}, 2_000
    payload = Jason.decode!(body)
    assert payload["counters"]["edges_missing"] == 0
    assert payload["counters"]["edges_idle"] == 1
    assert length(payload["artifacts"]) == 1
  end
end
