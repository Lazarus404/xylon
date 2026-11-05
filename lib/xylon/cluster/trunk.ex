defmodule Xylon.Cluster.Trunk do
  @moduledoc """
  Hub-to-hub trunk connect helper for multi-home rooms.

  ## What problem this solves

  Phase 10 pins multi-home Sessions to regional hubs. Connecting regions must
  call `Manager.connect_remote/3` only from the local hub and record cohost
  presence for placement.

  ## RFCs

  None for control; pipe media uses RFC 3711 via `XGW.Trunk.Pipe`.
  """

  alias Xylon.Cluster
  alias Xylon.Cluster.Presence
  alias Xylon.Session
  alias Xylon.Trunk.Manager

  @doc """
  Connects this hub's session to `peer_hub_node` for `session_key`.

  Requires `Cluster.hub?/0`. Creates the local Session if missing when
  `:module_id` is provided. Records presence cohosts for both regions.
  """
  @spec connect_hubs({term(), term()}, node(), keyword()) ::
          {:ok, Xylon.Participant.t()} | {:error, term()}
  def connect_hubs(session_key, peer_hub_node, opts)
      when is_tuple(session_key) and is_atom(peer_hub_node) and is_list(opts) do
    with :ok <- require_hub(),
         {:ok, session} <- ensure_session(session_key, opts) do
      opts = Keyword.put(opts, :session_key, session_key)

      case Manager.connect_remote(session, peer_hub_node, opts) do
        {:ok, _participant} = ok ->
          Presence.init!()
          Presence.put_cohost(session_key, Cluster.local_region(), Node.self())

          peer_region =
            try do
              :erpc.call(peer_hub_node, Cluster, :local_region, [])
            catch
              _, _ -> "remote"
            end

          Presence.put_cohost(session_key, peer_region, peer_hub_node)

          {tenant_id, session_id} = session_key
          _ = Session.maybe_include_cohost_recording(tenant_id, session_id, peer_hub_node)

          ok

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Disconnects the local trunk (if any) and reconnects to `peer_hub_node`.

  Used after peer hub failover. Opts match `connect_hubs/3`; requires
  `:peer_hub_node` or `:peer_region` (resolve current hub via `:erpc`).
  """
  @spec reconnect_cohosts({term(), term()}, keyword()) ::
          {:ok, Xylon.Participant.t()} | {:error, term()}
  def reconnect_cohosts(session_key, opts)
      when is_tuple(session_key) and is_list(opts) do
    with :ok <- require_hub(),
         {:ok, session} <- ensure_session(session_key, opts),
         {:ok, peer} <- resolve_peer_hub(opts) do
      trunk_id = Keyword.get(opts, :trunk_id, "trunk")
      _ = Manager.disconnect(session, trunk_id)
      connect_hubs(session_key, peer, opts)
    end
  end

  defp resolve_peer_hub(opts) do
    case Keyword.get(opts, :peer_hub_node) do
      node when is_atom(node) and node != nil ->
        {:ok, node}

      _ ->
        case Keyword.get(opts, :peer_region) do
          region when is_binary(region) or is_atom(region) ->
            region_s = to_string(region)

            peer =
              Enum.find(Node.list(), fn n ->
                try do
                  :erpc.call(n, Cluster, :local_region, []) == region_s and
                    :erpc.call(n, Cluster, :hub?, [])
                catch
                  _, _ -> false
                end
              end)

            if peer, do: {:ok, peer}, else: {:error, :peer_hub_not_found}

          _ ->
            {:error, :peer_hub_required}
        end
    end
  end

  defp require_hub do
    if Cluster.hub?() do
      :ok
    else
      {:error, :not_hub}
    end
  end

  defp ensure_session({tenant_id, session_id} = key, opts) do
    case Registry.lookup(Xylon.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        module_id = Keyword.fetch!(opts, :module_id)
        backend_opts = Keyword.get(opts, :backend_opts, [])
        Session.create(tenant_id, session_id, module_id, backend_opts)
    end
  end
end
