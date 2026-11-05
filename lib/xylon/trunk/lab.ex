defmodule Xylon.Trunk.Lab do
  @moduledoc """
  Lab helpers for multi-node multi-home cascade tests.

  ## What problem this solves

  ExUnit needs BEAM nodes sharing code paths to prove the same
  `{tenant_id, session_id}` co-hosts across edges. This module starts
  longname peers with Erlang dist for **control only**. Production regional
  membership uses `Xylon.Cluster` + `libcluster`.

  ## Internal

  Test/lab helper -- not the product clustering API.

  ## RFCs

  None.
  """

  @cookie :xylon_trunk_lab

  @doc """
  Starts this VM as `edge_a@127.0.0.1` and a peer as `edge_b@127.0.0.1`.

  Returns `{:ok, %{a: node_a, b: node_b, peer_pid: pid, stop: fun}}`.
  """
  @spec start_pair() :: {:ok, map()} | {:error, term()}
  def start_pair do
    case ensure_distributed!() do
      :ok -> do_start_pair()
      {:error, _} = err -> err
    end
  end

  @doc """
  Starts two hub nodes with distinct `region_id` values (control dist only).

  `regions` is a two-element list of region id strings. Local node gets the
  first region; the peer gets the second. Each enables `Xylon.Cluster.Hub`.

  Returns `{:ok, %{a: node, b: node, regions: {ra, rb}, stop: fun}}`.
  """
  @spec start_hubs([String.t()]) :: {:ok, map()} | {:error, term()}
  def start_hubs([region_a, region_b])
      when is_binary(region_a) and is_binary(region_b) do
    with {:ok, pair} <- start_pair() do
      :ok = configure_hub(Node.self(), region_a, 10)
      :ok = :erpc.call(pair.b, __MODULE__, :configure_hub, [pair.b, region_b, 10])

      {:ok,
       Map.merge(pair, %{
         regions: {region_a, region_b}
       })}
    end
  end

  @doc false
  def configure_hub(_node, region_id, priority)
      when is_binary(region_id) and is_integer(priority) do
    Application.put_env(:xylon, :cluster,
      enabled: true,
      region_id: region_id,
      hub_priority: priority,
      topologies: []
    )

    case Process.whereis(Xylon.Cluster.Hub) do
      nil ->
        case Xylon.Cluster.Hub.start([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok = Xylon.Cluster.Hub.set_membership_override(nil)
        :ok = Xylon.Cluster.Hub.reelect()
        :ok
    end
  end

  @doc """
  Starts an extra hub peer for failover lab tests.

  `name` is a short atom (e.g. `:edge_c`); node becomes `name@127.0.0.1`.
  """
  @spec start_extra_hub(String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def start_extra_hub(region_id, name \\ :edge_c)
      when is_binary(region_id) and is_atom(name) do
    with :ok <- ensure_distributed!() do
      case :peer.start(%{
             name: name,
             host: ~c"127.0.0.1",
             longnames: true,
             args: [~c"-setcookie", Atom.to_charlist(@cookie)]
           }) do
        {:ok, peer_pid, node} ->
          :ok = sync_paths(node)
          :ok = ensure_apps(node)
          :ok = :erpc.call(node, __MODULE__, :configure_hub, [node, region_id, 10])

          stop = fn ->
            try do
              _ = :peer.stop(peer_pid)
            catch
              _, _ -> :ok
            end

            :ok
          end

          {:ok, %{node: node, peer_pid: peer_pid, stop: stop, region: region_id}}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, other}
      end
    end
  end

  defp do_start_pair do
    node_a = Node.self()

    case :peer.start(%{
           name: :edge_b,
           host: ~c"127.0.0.1",
           longnames: true,
           args: [~c"-setcookie", Atom.to_charlist(@cookie)]
         }) do
      {:ok, peer_pid, node_b} ->
        :ok = sync_paths(node_b)
        :ok = ensure_apps(node_b)

        stop = fn ->
          try do
            _ = :peer.stop(peer_pid)
          catch
            _, _ -> :ok
          end

          :ok
        end

        {:ok, %{a: node_a, b: node_b, peer_pid: peer_pid, stop: stop}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp ensure_distributed! do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    case Node.self() do
      :nonode@nohost ->
        case Node.start(:"edge_a@127.0.0.1", :longnames) do
          {:ok, _} ->
            true = Node.set_cookie(@cookie)
            :ok

          {:error, {:already_started, _}} ->
            true = Node.set_cookie(@cookie)
            :ok

          {:error, reason} ->
            {:error, {:node_start, reason}}
        end

      _ ->
        true = Node.set_cookie(@cookie)
        :ok
    end
  end

  defp sync_paths(node) do
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    :ok
  end

  defp ensure_apps(node) do
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:xylon])

    Enum.each(
      [:xylon_datachannel_backend, :xylon_conference_backend],
      fn app ->
        _ = :erpc.call(node, Application, :ensure_all_started, [app])
      end
    )

    :ok
  end
end
