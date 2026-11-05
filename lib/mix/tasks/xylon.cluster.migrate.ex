defmodule Mix.Tasks.Xylon.Cluster.Migrate do
  @moduledoc """
  Trigger a lab migrate_required notify and print Placement target.

  ## What problem this solves

  Operators and tests need to exercise the ICE-restart drain path without
  killing a node. This prints the recommended edge for a session after notify.

      mix xylon.cluster.migrate TENANT SESSION --reason edge_down

  Client contract: on `migrate_required`, call place / `GET /place` and send a
  new JSEP offer (ICE restart) to `target.edge_url`.

  ## RFCs

  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE restart
  """
  use Mix.Task

  @shortdoc "Notify migrate_required and print Placement target"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [reason: :string],
        aliases: [r: :reason]
      )

    case rest do
      [tenant, session | _] ->
        reason =
          case Keyword.get(opts, :reason, "edge_down") do
            "hub_changed" -> :hub_changed
            _ -> :edge_down
          end

        key = {tenant, session}
        :ok = Xylon.Cluster.Migrate.notify_local_clients(key, reason)

        multi? = reason in [:edge_down, :hub_changed]

        {:ok, place} =
          Xylon.Cluster.Placement.recommend(
            tenant_id: tenant,
            session_id: session,
            multi_home: multi?,
            region_hint: Xylon.Cluster.local_region(),
            edge_urls:
              Application.get_env(:xylon, :cluster, []) |> Keyword.get(:edge_urls, %{})
          )

        Mix.shell().info(
          Jason.encode!(%{
            type: "migrate_required",
            reason: reason,
            session_key: [tenant, session],
            target: %{
              edge_url: place.edge_url,
              node: Atom.to_string(place.node),
              region_id: place.region_id,
              role: place.role
            }
          })
        )

      _ ->
        Mix.raise("usage: mix xylon.cluster.migrate TENANT SESSION [--reason edge_down|hub_changed]")
    end
  end
end
