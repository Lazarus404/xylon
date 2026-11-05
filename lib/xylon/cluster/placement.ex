defmodule Xylon.Cluster.Placement do
  @moduledoc """
  Off-path placement helper for single-home and multi-home joins.

  ## What problem this solves

  Clients need a recommended edge URL/node before WebRTC. Multi-home rooms pin
  to the regional hub; single-home stays sticky on the first assigned node.
  Non-accepting (draining) nodes are skipped so new rooms land elsewhere.
  This module never sits on the RTP path.

  ## RFCs

  None.
  """

  alias Xylon.Cluster
  alias Xylon.Cluster.{Accepting, Hub, Presence}

  @type recommend_opts :: [
          {:tenant_id, term()}
          | {:session_id, term()}
          | {:region_hint, String.t() | atom()}
          | {:multi_home, boolean()}
          | {:edge_urls, %{optional(String.t()) => String.t()}}
          | {:nodes, [node()]}
          | {:hub_node, node() | nil}
          | {:accepting, %{optional(node()) => boolean()}}
        ]

  @doc """
  Recommends an edge for `{tenant_id, session_id}`.

  Options:

  * `:tenant_id` / `:session_id` (required)
  * `:region_hint` - preferred region id (default `Cluster.local_region/0`)
  * `:multi_home` - when true, returns the regional hub
  * `:edge_urls` - map of region_id => public URL
  * `:nodes` / `:hub_node` - inject membership for tests
  * `:accepting` - optional `%{node => boolean}` inject for tests
  """
  @spec recommend(recommend_opts()) ::
          {:ok, %{edge_url: String.t() | nil, node: node(), region_id: String.t(), role: :hub | :worker}}
          | {:error, term()}
  def recommend(opts) when is_list(opts) do
    tenant = Keyword.fetch!(opts, :tenant_id)
    session = Keyword.fetch!(opts, :session_id)
    key = {tenant, session}
    region = opts |> Keyword.get(:region_hint, Cluster.local_region()) |> to_string()
    multi? = Keyword.get(opts, :multi_home, false) == true
    edge_urls = Keyword.get(opts, :edge_urls, %{})
    nodes = Keyword.get(opts, :nodes) || Cluster.nodes_in_region()
    hub = Keyword.get(opts, :hub_node) || Hub.hub_node() || Node.self()
    accepting_map = Keyword.get(opts, :accepting)

    Presence.init!()
    Accepting.init!()

    accepting? = fn node -> node_accepting?(node, accepting_map) end

    cond do
      multi? ->
        if accepting?.(hub) do
          Presence.put_cohost(key, region, hub)

          {:ok,
           %{
             edge_url: Map.get(edge_urls, region),
             node: hub,
             region_id: region,
             role: :hub
           }}
        else
          {:error, :no_accepting_nodes}
        end

      home = Presence.home(key) ->
        if accepting?.(home) do
          {:ok,
           %{
             edge_url: Map.get(edge_urls, region),
             node: home,
             region_id: region,
             role: role_for(home, hub)
           }}
        else
          _ = Presence.clear_home_key(key)
          pick_new(key, region, edge_urls, nodes, hub, accepting?)
        end

      true ->
        pick_new(key, region, edge_urls, nodes, hub, accepting?)
    end
  end

  defp pick_new(key, region, edge_urls, nodes, hub, accepting?) do
    candidates = Enum.filter(nodes, accepting?)

    case candidates do
      [] ->
        {:error, :no_accepting_nodes}

      list ->
        node = Enum.min_by(list, &Atom.to_string/1)
        Presence.put_home(key, node)

        {:ok,
         %{
           edge_url: Map.get(edge_urls, region),
           node: node,
           region_id: region,
           role: role_for(node, hub)
         }}
    end
  end

  defp node_accepting?(node, nil), do: Accepting.accepting_on?(node)

  defp node_accepting?(node, map) when is_map(map) do
    Map.get(map, node, true) == true
  end

  defp role_for(node, hub) when node == hub, do: :hub
  defp role_for(_node, _hub), do: :worker
end
