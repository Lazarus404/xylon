defmodule Mix.Tasks.Xylon.Cluster.Bootstrap do
  @moduledoc """
  Print recommended env and sample `libcluster` Gossip config for a region.

  ## What problem this solves

  SaaS deploy teams own Terraform/VPC; this task prints the Xylon env contract
  and a lab-friendly Gossip topology skeleton so operators can wire releases
  without inventing keys from scratch.

      mix xylon.cluster.bootstrap

  Does not write infra files.

  ## RFCs

  None.
  """
  use Mix.Task

  @shortdoc "Print Xylon cluster env + sample libcluster topology"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("""
    # Xylon cluster env contract (SaaS provisions cookie/TLS/DNS)

    export XYLON_REGION_ID=us-west-2
    export XYLON_HUB_PRIORITY=0
    # Erlang cookie + TLS distribution are host concerns

    # config/runtime.exs sketch (Gossip lab; prefer DNS/K8s in product):

    config :xylon, :cluster,
      enabled: true,
      region_id: System.get_env("XYLON_REGION_ID") || "local",
      hub_priority: String.to_integer(System.get_env("XYLON_HUB_PRIORITY") || "0"),
      topologies: [
        xylon: [
          strategy: Cluster.Strategy.Gossip
        ]
      ],
      edge_urls: %{
        "us-west-2" => "https://usw2.example",
        "eu-central-1" => "https://euc1.example"
      }

    # Trunk directional keys (example names):
    # XYLON_TRUNK_KEY_AB / XYLON_TRUNK_SALT_AB / XYLON_TRUNK_KEY_BA / XYLON_TRUNK_SALT_BA
    """)
  end
end
