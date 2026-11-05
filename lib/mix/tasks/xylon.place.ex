defmodule Mix.Tasks.Xylon.Place do
  @moduledoc """
  Print placement recommendation for a tenant session.

  ## What problem this solves

  Clients and gateways need a recommended edge before WebRTC. Multi-home rooms
  pin to the regional hub; single-home stays sticky.

      mix xylon.place TENANT SESSION [--region REGION] [--multi-home]

  ## RFCs

  None.
  """
  use Mix.Task

  @shortdoc "Recommend edge URL/node for a session"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [region: :string, multi_home: :boolean],
        aliases: [r: :region, m: :multi_home]
      )

    case rest do
      [tenant, session | _] ->
        recommend_opts =
          [
            tenant_id: tenant,
            session_id: session,
            multi_home: Keyword.get(opts, :multi_home, false)
          ]
          |> then(fn o ->
            case Keyword.get(opts, :region) do
              nil -> o
              region -> Keyword.put(o, :region_hint, region)
            end
          end)
          |> then(fn o ->
            urls = Application.get_env(:xylon, :cluster, []) |> Keyword.get(:edge_urls, %{})
            Keyword.put(o, :edge_urls, urls)
          end)

        case Xylon.Cluster.Placement.recommend(recommend_opts) do
          {:ok, place} ->
            Mix.shell().info(Jason.encode!(%{
              edge_url: place.edge_url,
              node: Atom.to_string(place.node),
              region_id: place.region_id,
              role: place.role
            }))

          {:error, reason} ->
            Mix.raise("place failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix xylon.place TENANT SESSION [--region REGION] [--multi-home]")
    end
  end
end
