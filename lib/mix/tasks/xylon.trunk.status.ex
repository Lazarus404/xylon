defmodule Mix.Tasks.Xylon.Trunk.Status do
  @moduledoc """
  Print cohost presence and local trunk Pipe stats for a session.

  ## What problem this solves

  Operators need a quick check that hubs co-host a room and that UDP counters
  move -- without putting RTP on Erlang dist.

      mix xylon.trunk.status TENANT SESSION

  ## RFCs

  None.
  """
  use Mix.Task

  @shortdoc "Show trunk cohosts and Pipe stats for a session"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [tenant, session | _] ->
        key = {tenant, session}
        Xylon.Cluster.Presence.init!()
        Mix.shell().info("cohosts=#{inspect(Xylon.Cluster.Presence.cohosts(key))}")
        Mix.shell().info("home=#{inspect(Xylon.Cluster.Presence.home(key))}")

        case Registry.lookup(Xylon.Registry, key) do
          [{session_pid, _}] ->
            pipe = Xylon.Trunk.Manager.trunk_pipe(session_pid, "trunk")

            if is_pid(pipe) do
              Mix.shell().info("pipe=#{inspect(pipe)} stats=#{inspect(XGW.Trunk.Pipe.stats(pipe))}")
            else
              Mix.shell().info("pipe=nil")
            end

          [] ->
            Mix.shell().info("session=not_local")
        end

      _ ->
        Mix.raise("usage: mix xylon.trunk.status TENANT SESSION")
    end
  end
end
