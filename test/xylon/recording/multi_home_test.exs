defmodule Xylon.Recording.MultiHomeTest do
  use ExUnit.Case, async: false

  @moduletag :dual_node

  alias Xylon.Cluster.Presence
  alias Xylon.Recording.MultiHomeHandler
  alias Xylon.Trunk.Lab

  defmodule CapturePlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pid = Application.get_env(:xylon, :recording_mh_webhook_test_pid)

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
    case Lab.start_pair() do
      {:ok, %{a: node_a, b: node_b, stop: stop}} ->
        on_exit(stop)

        Application.put_env(:xylon, :recording, handler: MultiHomeHandler)

        :ok =
          :erpc.call(node_b, Application, :put_env, [
            :xylon,
            :recording,
            [handler: MultiHomeHandler]
          ])

        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen)
        :ok = :gen_tcp.close(listen)

        {:ok, bandit} =
          Bandit.start_link(plug: CapturePlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

        url = "http://127.0.0.1:#{port}/"
        Application.put_env(:xylon, :recording_mh_webhook_test_pid, self())
        Application.put_env(:xylon, :recording_erpc_trace, self())

        Application.put_env(:xylon, :control,
          enabled: true,
          webhook_url: url,
          webhook_secret: "mh-secret"
        )

        :ok =
          :erpc.call(node_b, Application, :put_env, [
            :xylon,
            :control,
            [enabled: true, webhook_url: url, webhook_secret: "mh-secret"]
          ])

        assert :ok = Xylon.attach(Xylon.Backend.Echo)
        assert :ok = :erpc.call(node_b, Xylon, :attach, [Xylon.Backend.Echo])
        assert {:module, _} = :erpc.call(node_b, Code, :ensure_loaded, [MultiHomeHandler])

        on_exit(fn ->
          Process.exit(bandit, :normal)
          Application.delete_env(:xylon, :recording)
          Application.delete_env(:xylon, :recording_mh_webhook_test_pid)
          Application.delete_env(:xylon, :recording_erpc_trace)
          Application.delete_env(:xylon, :control)
        end)

        {:ok, %{node_a: node_a, node_b: node_b}}

      {:error, reason} ->
        {:ok, %{skip: reason}}
    end
  end

  test "dual-edge stop emits one webhook with both edge_nodes", ctx do
    if Map.has_key?(ctx, :skip) do
      flunk("dual-node start failed: #{inspect(ctx.skip)}")
    end

    %{node_a: node_a, node_b: node_b} = ctx
    sid = "mh-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    Presence.put_cohost(key, "region-a", node_a)
    Presence.put_cohost(key, "region-b", node_b)
    :ok = :erpc.call(node_b, Presence, :put_cohost, [key, "region-a", node_a])
    :ok = :erpc.call(node_b, Presence, :put_cohost, [key, "region-b", node_b])

    assert {:ok, session_a} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, _session_b} = :erpc.call(node_b, Xylon.Session, :create, ["t1", sid, :echo])

    assert {:ok, started} = Xylon.Session.start_recording(session_a)
    Process.put(:mh_erpcs, [])
    assert {:ok, _} = Xylon.Session.stop_recording(session_a)

    payload = await_recording_webhook()

    assert payload["type"] == "recording.completed"
    assert payload["recording_id"] == started.recording_id

    edges =
      payload["artifacts"]
      |> Enum.map(& &1["edge_node"])
      |> Enum.sort()

    assert edges == Enum.sort([to_string(node_a), to_string(node_b)])
    assert payload["counters"]["edges_missing"] == 0

    erpc_calls = Enum.reverse(Process.get(:mh_erpcs, [])) ++ drain_erpc_trace([])
    assert erpc_calls != []

    Enum.each(erpc_calls, fn {mod, _fun, args} ->
      assert mod in [Xylon.Session, Xylon.Recording.Aggregator]
      refute Enum.any?(args, &match?(%XMediaLib.Rtp{}, &1))
      refute Enum.any?(args, &match?({:struct, XMediaLib.Rtp, _}, &1))
    end)
  end

  test "late cohost include adds peer to expected set", ctx do
    if Map.has_key?(ctx, :skip) do
      flunk("dual-node start failed: #{inspect(ctx.skip)}")
    end

    %{node_a: node_a, node_b: node_b} = ctx
    sid = "mh-late-#{System.unique_integer([:positive])}"
    key = {"t1", sid}

    # Start with only local cohost presence so start does not fan out yet.
    Presence.put_cohost(key, "region-a", node_a)

    assert {:ok, session_a} = Xylon.Session.create("t1", sid, :echo)
    assert {:ok, _session_b} = :erpc.call(node_b, Xylon.Session, :create, ["t1", sid, :echo])

    assert {:ok, started} = Xylon.Session.start_recording(session_a)

    Presence.put_cohost(key, "region-b", node_b)
    :ok = :erpc.call(node_b, Presence, :put_cohost, [key, "region-a", node_a])
    :ok = :erpc.call(node_b, Presence, :put_cohost, [key, "region-b", node_b])

    assert :ok = Xylon.Session.maybe_include_cohost_recording("t1", sid, node_b)

    assert {:ok, _} = Xylon.Session.stop_recording(session_a)

    payload = await_recording_webhook()
    assert payload["recording_id"] == started.recording_id

    edges =
      payload["artifacts"]
      |> Enum.map(& &1["edge_node"])
      |> Enum.sort()

    assert edges == Enum.sort([to_string(node_a), to_string(node_b)])
  end

  defp await_recording_webhook do
    receive do
      {:webhook, body} ->
        decoded = Jason.decode!(body)

        if decoded["type"] in ["recording.completed", "recording.failed"] do
          decoded
        else
          await_recording_webhook()
        end

      {:recording_erpc, mod, fun, args} ->
        Process.put(:mh_erpcs, [{mod, fun, args} | Process.get(:mh_erpcs, [])])
        await_recording_webhook()
    after
      5_000 -> flunk("no recording webhook")
    end
  end

  defp drain_erpc_trace(acc) do
    receive do
      {:recording_erpc, mod, fun, args} ->
        drain_erpc_trace([{mod, fun, args} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
