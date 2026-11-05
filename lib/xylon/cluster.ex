defmodule Xylon.Cluster do
  @moduledoc """
  In-region BEAM membership and hub queries (control plane only).

  ## What problem this solves

  Production N-region multi-home needs regional node discovery (`libcluster`)
  and a deterministic hub for inter-region trunks. Media still uses
  `XGW.Trunk.Pipe`; this module never carries RTP/SRTP/datachannel bytes.

  ## RFCs

  None for control; trunk media uses RFC 3711 via `XGW.Trunk.Pipe`.
  """

  alias Xylon.Cluster.Hub

  @doc """
  Returns cluster config keyword list.
  """
  @spec config() :: keyword()
  def config, do: Application.get_env(:xylon, :cluster, [])

  @doc """
  True when cluster children are enabled in config.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc """
  Local region id string (config `:region_id`, else env `XYLON_REGION_ID`, else `"local"`).
  """
  @spec local_region() :: String.t()
  def local_region do
    cluster = config()

    cond do
      region = Keyword.get(cluster, :region_id) ->
        to_string(region)

      id = System.get_env("XYLON_REGION_ID") ->
        id

      true ->
        "local"
    end
  end

  @doc """
  Connected nodes including self (in-region membership view for lab/product).
  """
  @spec nodes_in_region() :: [node()]
  def nodes_in_region, do: [Node.self() | Node.list()] |> Enum.uniq() |> Enum.sort()

  @doc """
  True when this VM is a distributed node (not `:nonode@nohost`).
  """
  @spec connected?() :: boolean()
  def connected?, do: Node.self() != :nonode@nohost

  @doc """
  Current elected hub node.
  """
  @spec hub_node() :: node() | nil
  def hub_node, do: Hub.hub_node()

  @doc """
  True when this node is the elected hub.
  """
  @spec hub?() :: boolean()
  def hub?, do: Hub.hub?()

  @doc """
  Raises if multi-home work is attempted on a non-hub node.
  """
  @spec ensure_hub!() :: :ok
  def ensure_hub! do
    if hub?() do
      :ok
    else
      raise "multi-home requires regional hub; this node is #{inspect(Node.self())} hub=#{inspect(hub_node())}"
    end
  end

  @doc """
  Supervisor children when `:cluster, enabled: true`.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    if enabled?() do
      topologies = Keyword.get(config(), :topologies, [])

      libcluster =
        if topologies != [] do
          [{Cluster.Supervisor, [topologies, [name: Xylon.ClusterSupervisor]]}]
        else
          []
        end

      libcluster ++ [Xylon.Cluster.Hub]
    else
      []
    end
  end
end
