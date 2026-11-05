defmodule Xylon.Control.Fleet do
  @moduledoc """
  Aggregates per-node load snapshots for Control fleet HTTP.

  ## What problem this solves

  Operators and the demo admin console need region/node load (session and
  participant counts) without scraping media. `local_node_snapshot/1` reads
  local Registry + Membership + Cluster presence; `collect_nodes/1` fans out
  via `:erpc` to `Xylon.Cluster.nodes_in_region/0` peers. Counts and ids only.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane fleet summary (JSON).
  """

  alias Xylon.Cluster
  alias Xylon.Cluster.Accepting
  alias Xylon.Cluster.Presence
  alias Xylon.Control.Membership

  @erpc_timeout_ms 2_000

  @doc """
  Local load snapshot for `tenant_id` on this node (string keys for JSON).
  """
  @spec local_node_snapshot(term()) :: map()
  def local_node_snapshot(tenant_id) do
    sessions =
      Registry.select(Xylon.Registry, [
        {{{tenant_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])

    session_count = length(sessions)

    participant_count =
      Enum.reduce(sessions, 0, fn {session_id, _pid}, acc ->
        acc + map_size(Membership.list(tenant_id, session_id))
      end)

    self_node = Node.self()

    cohost_hub_count =
      Presence.cohost_session_keys()
      |> Enum.filter(fn {t, _} -> t == tenant_id end)
      |> Enum.count(fn key ->
        Enum.any?(Presence.cohosts(key), fn %{hub_node: hub} -> hub == self_node end)
      end)

    %{
      "node" => Atom.to_string(self_node),
      "region" => Cluster.local_region(),
      "session_count" => session_count,
      "participant_count" => participant_count,
      "hub" => Cluster.hub?(),
      "cohost_hub_count" => cohost_hub_count,
      "reachable" => true,
      "accepting" => Accepting.accepting?()
    }
  end

  @doc """
  Collects snapshots from self + peers in `nodes_in_region/0`.

  Peer failures yield an unreachable stub with zero counts.
  """
  @spec collect_nodes(term()) :: [map()]
  def collect_nodes(tenant_id) do
    self = Node.self()

    Cluster.nodes_in_region()
    |> Enum.map(fn
      ^self ->
        local_node_snapshot(tenant_id)

      peer ->
        case safe_erpc(peer, __MODULE__, :local_node_snapshot, [tenant_id]) do
          {:ok, snap} when is_map(snap) ->
            snap

          _ ->
            unreachable_stub(peer)
        end
    end)
    |> Enum.sort_by(& &1["node"])
  end

  @doc """
  Builds summary map from node snapshot list (pure; testable with synthetics).
  """
  @spec summary_from_nodes([map()]) :: map()
  def summary_from_nodes(nodes) when is_list(nodes) do
    regions =
      nodes
      |> Enum.map(& &1["region"])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    hub_node =
      case Enum.find(nodes, &(&1["hub"] == true)) do
        %{"node" => n} -> n
        _ -> hub_node_string()
      end

    {healthy, unhealthy} =
      Enum.reduce(nodes, {0, 0}, fn n, {h, u} ->
        if Map.get(n, "reachable", true) == false do
          {h, u + 1}
        else
          {h + 1, u}
        end
      end)

    %{
      "regions" => regions,
      "node_count" => length(nodes),
      "healthy_count" => healthy,
      "unhealthy_count" => unhealthy,
      "session_count" => Enum.reduce(nodes, 0, fn n, acc -> acc + int_field(n, "session_count") end),
      "participant_count" =>
        Enum.reduce(nodes, 0, fn n, acc -> acc + int_field(n, "participant_count") end),
      "hub_node" => hub_node,
      "connected" => Cluster.connected?()
    }
  end

  defp unreachable_stub(peer) when is_atom(peer) do
    region =
      case safe_erpc(peer, Cluster, :local_region, []) do
        {:ok, r} when is_binary(r) -> r
        _ -> ""
      end

    %{
      "node" => Atom.to_string(peer),
      "region" => region,
      "session_count" => 0,
      "participant_count" => 0,
      "hub" => false,
      "cohost_hub_count" => 0,
      "reachable" => false,
      "accepting" => false
    }
  end

  defp hub_node_string do
    case Cluster.hub_node() do
      nil -> ""
      n when is_atom(n) -> Atom.to_string(n)
    end
  end

  defp int_field(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp safe_erpc(node, mod, fun, args) do
    try do
      {:ok, :erpc.call(node, mod, fun, args, @erpc_timeout_ms)}
    catch
      :exit, _ -> {:error, :exit}
      :error, _ -> {:error, :error}
      :throw, _ -> {:error, :throw}
    end
  end
end
