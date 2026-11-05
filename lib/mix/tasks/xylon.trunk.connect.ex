defmodule Mix.Tasks.Xylon.Trunk.Connect do
  @moduledoc """
  Hub-to-hub `connect_remote` for a multi-home session.

  ## What problem this solves

  Operators on the regional hub need to peer another region's hub without
  writing Elixir. Keys come from env; media stays on UDP+SRTP.

      mix xylon.trunk.connect TENANT SESSION PEER_NODE MODULE_ID

  Env: `XYLON_TRUNK_KEY_AB`, `XYLON_TRUNK_SALT_AB`, `XYLON_TRUNK_KEY_BA`,
  `XYLON_TRUNK_SALT_BA` (hex or raw; lab may use master aliases).

  ## RFCs

  None for control; pipe uses RFC 3711.
  """
  use Mix.Task

  @shortdoc "Connect hub trunk to a peer hub node"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [tenant, session, peer, module_id | _] ->
        peer_node = String.to_atom(peer)
        mod = String.to_atom(module_id)
        key = {tenant, session}

        opts =
          [
            module_id: mod,
            key_ab: env_bin!("XYLON_TRUNK_KEY_AB"),
            salt_ab: env_bin!("XYLON_TRUNK_SALT_AB"),
            key_ba: env_bin!("XYLON_TRUNK_KEY_BA"),
            salt_ba: env_bin!("XYLON_TRUNK_SALT_BA")
          ]

        case Xylon.Cluster.Trunk.connect_hubs(key, peer_node, opts) do
          {:ok, participant} ->
            Mix.shell().info("connected trunk=#{inspect(participant.id)} pipe=#{inspect(participant.peer_ref)}")

          {:error, reason} ->
            Mix.raise("trunk connect failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix xylon.trunk.connect TENANT SESSION PEER_NODE MODULE_ID")
    end
  end

  defp env_bin!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("missing env #{name}")
      <<"0x", hex::binary>> -> Base.decode16!(hex, case: :mixed)
      bin -> bin
    end
  end
end
