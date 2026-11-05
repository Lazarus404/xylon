defmodule Xylon.Cluster.Presence do
  @moduledoc """
  ETS presence for multi-home cohosts and single-home sticky homes.

  ## What problem this solves

  Placement and hub trunk connect need to know which regional hubs co-host a
  `{tenant_id, session_id}`, and where a single-home Session already lives.
  This table is control-plane only -- never media.

  ## RFCs

  None.
  """

  @table :xylon_cluster_presence

  @doc """
  Creates the presence ETS table if missing.
  """
  @spec init!() :: :ok
  def init! do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Clears all presence rows (tests).
  """
  @spec reset!() :: :ok
  def reset! do
    init!()
    true = :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Records or replaces the hub node co-hosting `session_key` in `region_id`.
  """
  @spec put_cohost({term(), term()}, String.t() | atom(), node()) :: :ok
  def put_cohost({_tenant, _session} = key, region_id, hub_node)
      when is_atom(hub_node) do
    init!()
    region = normalize_region(region_id)
    cohosts = Map.put(cohost_map(key), region, hub_node)
    true = :ets.insert(@table, {{:cohost, key}, cohosts})
    :ok
  end

  @doc """
  Returns cohost entries for `session_key`.
  """
  @spec cohosts({term(), term()}) :: [%{region_id: String.t(), hub_node: node()}]
  def cohosts({_tenant, _session} = key) do
    init!()

    cohost_map(key)
    |> Enum.map(fn {region_id, hub_node} ->
      %{region_id: region_id, hub_node: hub_node}
    end)
    |> Enum.sort_by(& &1.region_id)
  end

  @doc """
  Sets the sticky single-home node for `session_key`.
  """
  @spec put_home({term(), term()}, node()) :: :ok
  def put_home({_tenant, _session} = key, node) when is_atom(node) do
    init!()
    true = :ets.insert(@table, {{:home, key}, node})
    :ok
  end

  @doc """
  Returns the sticky single-home node, or `nil`.
  """
  @spec home({term(), term()}) :: node() | nil
  def home({_tenant, _session} = key) do
    init!()

    case :ets.lookup(@table, {:home, key}) do
      [{_, node}] -> node
      [] -> nil
    end
  end

  @doc """
  Removes cohost entries whose hub_node equals `dead_node`.

  Returns session keys that were updated.
  """
  @spec clear_cohost_node(node()) :: [{term(), term()}]
  def clear_cohost_node(dead_node) when is_atom(dead_node) do
    init!()

    :ets.match_object(@table, {{:cohost, :_}, :_})
    |> Enum.reduce([], fn {{:cohost, key}, map}, acc ->
      cleaned =
        map
        |> Enum.reject(fn {_region, hub} -> hub == dead_node end)
        |> Map.new()

      if map_size(cleaned) != map_size(map) do
        true = :ets.insert(@table, {{:cohost, key}, cleaned})
        [key | acc]
      else
        acc
      end
    end)
  end

  @doc """
  Clears sticky home for `session_key` when present.
  """
  @spec clear_home_key({term(), term()}) :: :ok
  def clear_home_key({_tenant, _session} = key) do
    init!()
    true = :ets.delete(@table, {:home, key})
    :ok
  end

  @doc """
  Clears sticky home when it equals `dead_node`. Returns affected keys.
  """
  @spec clear_home_node(node()) :: [{term(), term()}]
  def clear_home_node(dead_node) when is_atom(dead_node) do
    init!()

    :ets.match_object(@table, {{:home, :_}, :_})
    |> Enum.reduce([], fn {{:home, key}, node}, acc ->
      if node == dead_node do
        true = :ets.delete(@table, {:home, key})
        [key | acc]
      else
        acc
      end
    end)
  end

  @doc """
  All session keys that have cohost rows.
  """
  @spec cohost_session_keys() :: [{term(), term()}]
  def cohost_session_keys do
    init!()

    :ets.match_object(@table, {{:cohost, :_}, :_})
    |> Enum.map(fn {{:cohost, key}, _} -> key end)
  end

  defp cohost_map(key) do
    case :ets.lookup(@table, {:cohost, key}) do
      [{_, map}] when is_map(map) -> map
      [] -> %{}
    end
  end

  defp normalize_region(region_id) when is_atom(region_id), do: Atom.to_string(region_id)
  defp normalize_region(region_id) when is_binary(region_id), do: region_id
end
