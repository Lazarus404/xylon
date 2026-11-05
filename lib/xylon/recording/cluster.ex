defmodule Xylon.Recording.Cluster do
  @moduledoc """
  `:erpc` control plane for multi-home recording start/stop/report.

  ## What problem this solves

  The coordinator Session that received Control `record/start` must fan out the
  same `recording_id` to cohost Sessions and collect finalize reports without
  sending live RTP over Erlang distribution.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon recording cluster control.
  """

  alias Xylon.Cluster.Presence
  alias Xylon.Recording.Aggregator
  alias Xylon.Session

  @doc """
  Returns cohost hub nodes for `session_key`, excluding `Node.self()`.
  """
  @spec peer_hubs({term(), term()}) :: [node()]
  def peer_hubs({_tenant, _session} = key) do
    Presence.cohosts(key)
    |> Enum.map(& &1.hub_node)
    |> Enum.reject(&(&1 == Node.self()))
    |> Enum.uniq()
  end

  @doc """
  Starts recording on each peer hub with shared context fields.

  Returns `{ok_nodes, errors}` where `ok_nodes` successfully started.
  """
  @spec broadcast_start({term(), term()}, map(), map()) :: {[node()], [{node(), term()}]}
  def broadcast_start({tenant_id, session_id} = key, ctx_fields, opts)
      when is_map(ctx_fields) and is_map(opts) do
    Enum.reduce(peer_hubs(key), {[], []}, fn node, {oks, errs} ->
      case start_on_peer(node, tenant_id, session_id, ctx_fields, opts) do
        :ok -> {[node | oks], errs}
        {:error, reason} -> {oks, [{node, reason} | errs]}
      end
    end)
    |> then(fn {oks, errs} -> {Enum.reverse(oks), Enum.reverse(errs)} end)
  end

  @doc """
  Starts recording on one peer hub (late cohost join mid-segment).
  """
  @spec start_on_peer(node(), term(), term(), map(), map()) :: :ok | {:error, term()}
  def start_on_peer(node, tenant_id, session_id, ctx_fields, opts)
      when is_atom(node) and is_map(ctx_fields) and is_map(opts) do
    case safe_erpc(node, Session, :recording_remote_start, [
           tenant_id,
           session_id,
           ctx_fields,
           opts
         ]) do
      {:ok, {:ok, _}} -> :ok
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, other}
      {:error, _} = err -> err
    end
  end

  @doc """
  Stops recording on peer hubs so each edge finalizes and reports.

  Uses a refreshed `Presence.cohosts/1` set so late joiners are included.
  `coordinator_node` receives `Aggregator.report_edge/2` from remotes.
  """
  @spec broadcast_stop({term(), term()}, binary(), node()) :: :ok
  def broadcast_stop({tenant_id, session_id} = key, recording_id, coordinator_node)
      when is_binary(recording_id) and is_atom(coordinator_node) do
    Enum.each(peer_hubs(key), fn node ->
      _ =
        safe_erpc(node, Session, :recording_remote_stop, [
          tenant_id,
          session_id,
          recording_id,
          coordinator_node
        ])
    end)

    :ok
  end

  @doc """
  Reports an edge finalize payload to the Aggregator on `coordinator_node`.
  """
  @spec report_to_coordinator(node(), binary(), map()) :: :ok | {:error, term()}
  def report_to_coordinator(coordinator_node, recording_id, report)
      when is_atom(coordinator_node) and is_binary(recording_id) and is_map(report) do
    if coordinator_node == Node.self() do
      Aggregator.report_edge(recording_id, report)
    else
      case safe_erpc(coordinator_node, Aggregator, :report_edge, [recording_id, report]) do
        {:ok, :ok} -> :ok
        {:ok, other} -> other
        {:error, _} = err -> err
      end
    end
  end

  defp safe_erpc(node, mod, fun, args) do
    trace_erpc(mod, fun, args)

    try do
      {:ok, :erpc.call(node, mod, fun, args)}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp trace_erpc(mod, fun, args) do
    case Application.get_env(:xylon, :recording_erpc_trace) do
      pid when is_pid(pid) ->
        send(pid, {:recording_erpc, mod, fun, erpc_arg_shapes(args)})

      _ ->
        :ok
    end
  end

  # Shapes only -- never forward live RTP binaries to the tracer.
  defp erpc_arg_shapes(args) when is_list(args) do
    Enum.map(args, fn
      %struct{} = s -> {:struct, struct, Map.keys(Map.from_struct(s))}
      bin when is_binary(bin) and byte_size(bin) > 64 -> {:binary, byte_size(bin)}
      other -> other
    end)
  end
end
