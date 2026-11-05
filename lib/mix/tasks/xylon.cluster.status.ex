defmodule Mix.Tasks.Xylon.Cluster.Status do
  @moduledoc """
  Print local region, membership, and elected hub.

  ## What problem this solves

  Operators need a one-shot view of in-region cluster health without attaching
  a remote console.

      mix xylon.cluster.status

  ## RFCs

  None.
  """
  use Mix.Task

  @shortdoc "Show Xylon cluster region, nodes, and hub"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    region = Xylon.Cluster.local_region()
    nodes = Xylon.Cluster.nodes_in_region()
    hub = Xylon.Cluster.hub_node()
    hub? = Xylon.Cluster.hub?()

    Mix.shell().info("region=#{region}")
    Mix.shell().info("connected=#{Xylon.Cluster.connected?()}")
    Mix.shell().info("nodes=#{inspect(nodes)}")
    Mix.shell().info("hub=#{inspect(hub)}")
    Mix.shell().info("hub?=#{hub?}")
  end
end
