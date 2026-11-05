defmodule Xylon.Cluster.Hub do
  @moduledoc """
  GenServer that elects and publishes the regional hub node.

  ## What problem this solves

  Placement and hub-to-hub trunks need a stable answer to "who is the hub in
  this region?" This process recomputes election when membership changes and
  stores the result in ETS for fast reads.

  ## RFCs

  None.
  """

  use GenServer

  alias Xylon.Cluster.HubElection
  alias Xylon.Cluster.Migrate

  @hub_table :xylon_cluster_hub
  @priority_table :xylon_cluster_priorities

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts the Hub unlinked (safe under `:erpc` on peer nodes).
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current elected hub node, or `nil` if unknown.
  """
  @spec hub_node() :: node() | nil
  def hub_node do
    ensure_hub_table!()

    case :ets.lookup(@hub_table, :hub) do
      [{:hub, node}] -> node
      [] -> nil
    end
  end

  @doc """
  True when this node is the elected hub.
  """
  @spec hub?() :: boolean()
  def hub?, do: hub_node() == Node.self()

  @doc """
  Registers a node's hub priority (lab / tests). Defaults to config priority for self.
  """
  @spec put_priority(node(), integer()) :: :ok
  def put_priority(node, priority) when is_atom(node) and is_integer(priority) do
    ensure_priority_table!()
    true = :ets.insert(@priority_table, {node, priority})
    _ = GenServer.cast(__MODULE__, :reelect)
    :ok
  end

  @doc """
  Forces re-election from current membership (tests).
  """
  @spec reelect() :: :ok
  def reelect, do: GenServer.call(__MODULE__, :reelect)

  @doc """
  Injects membership candidates for tests (bypasses Node.list).
  Pass `nil` to clear override.
  """
  @spec set_membership_override([{node(), integer()}] | nil) :: :ok
  def set_membership_override(candidates) do
    GenServer.call(__MODULE__, {:set_membership_override, candidates})
  end

  @impl true
  def init(_opts) do
    ensure_hub_table!()
    ensure_priority_table!()
    :ok = :net_kernel.monitor_nodes(true, [:nodedown_reason])
    state = %{override: nil}
    {:ok, recompute(state)}
  end

  @impl true
  def handle_call(:reelect, _from, state), do: {:reply, :ok, recompute(state)}

  def handle_call({:set_membership_override, candidates}, _from, state) do
    {:reply, :ok, recompute(%{state | override: candidates})}
  end

  @impl true
  def handle_cast(:reelect, state), do: {:noreply, recompute(state)}

  @impl true
  def handle_info({:nodeup, node, _}, state) do
    state = recompute(state)
    _ = Migrate.on_peer_hub_up(node)
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _}, state) do
    state = recompute(state)
    _ = Migrate.on_peer_hub_down(node)
    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    state = recompute(state)
    _ = Migrate.on_peer_hub_up(node)
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    state = recompute(state)
    _ = Migrate.on_peer_hub_down(node)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp recompute(state) do
    old = hub_node()

    candidates =
      case state.override do
        nil -> live_candidates()
        list when is_list(list) -> list
      end

    hub =
      case candidates do
        [] -> Node.self()
        list -> HubElection.elect(list)
      end

    true = :ets.insert(@hub_table, {:hub, hub})

    if old != hub do
      _ = Migrate.on_hub_changed(old, hub)
    end

    state
  end

  defp live_candidates do
    ensure_priority_table!()
    default_pri = hub_priority()
    self = Node.self()
    local_region = Xylon.Cluster.local_region()

    [self | Node.list()]
    |> Enum.uniq()
    |> Enum.filter(fn node -> node_region(node) == local_region end)
    |> Enum.map(fn node ->
      pri =
        case :ets.lookup(@priority_table, node) do
          [{^node, p}] ->
            p

          [] ->
            if node == self, do: default_pri, else: remote_priority(node)
        end

      {node, pri}
    end)
  end

  defp node_region(node) do
    if node == Node.self() do
      Xylon.Cluster.local_region()
    else
      try do
        :erpc.call(node, Xylon.Cluster, :local_region, [])
      catch
        _, _ -> nil
      end
    end
  end

  defp remote_priority(node) do
    try do
      :erpc.call(node, Application, :get_env, [:xylon, :cluster, []])
      |> Keyword.get(:hub_priority, 0)
    catch
      _, _ -> 0
    end
  end

  defp hub_priority do
    cluster = Application.get_env(:xylon, :cluster, [])

    cond do
      Keyword.has_key?(cluster, :hub_priority) ->
        Keyword.get(cluster, :hub_priority, 0)

      s = System.get_env("XYLON_HUB_PRIORITY") ->
        String.to_integer(s)

      true ->
        0
    end
  end

  defp ensure_hub_table! do
    case :ets.whereis(@hub_table) do
      :undefined ->
        _ = :ets.new(@hub_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_priority_table! do
    case :ets.whereis(@priority_table) do
      :undefined ->
        _ = :ets.new(@priority_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
