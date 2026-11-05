defmodule Xylon.Cluster.Migrate do
  @moduledoc """
  Control-plane live migration for hub failover and edge loss.

  ## What problem this solves

  When a regional hub changes or a peer edge disappears, multi-home rooms must
  drop dead cohosts, re-peer trunks, and tell local clients to ICE-restart via
  Placement. Media stays on UDP+SRTP; this module is control only.

  ## RFCs

  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- client ICE restart
  - Trunk media: RFC 3711 via `XGW.Trunk.Pipe`
  """

  alias Xylon.Cluster
  alias Xylon.Cluster.{Placement, Presence, Trunk}
  alias Xylon.Trunk.Manager

  @subscribers :xylon_cluster_migrate_subs
  @pending :xylon_cluster_migrate_pending

  @doc """
  Called when the elected hub for this region changes.
  """
  @spec on_hub_changed(node() | nil, node() | nil) :: :ok
  def on_hub_changed(old_hub, new_hub) when old_hub == new_hub, do: :ok

  def on_hub_changed(old_hub, new_hub) do
    Presence.init!()

    if is_atom(old_hub) and old_hub != nil do
      _ = Presence.clear_cohost_node(old_hub)
    end

    if Cluster.hub?() and is_atom(new_hub) and new_hub == Node.self() do
      Enum.each(Presence.cohost_session_keys(), fn key ->
        notify_local_clients(key, :hub_changed)
      end)
    end

    :ok
  end

  @doc """
  Called when a peer node goes down. Clears Presence rows pointing at it,
  disconnects local trunks, queues auto-reconnect, and notifies clients.
  """
  @spec on_peer_hub_down(node()) :: :ok
  def on_peer_hub_down(dead_node) when is_atom(dead_node) do
    Presence.init!()
    ensure_pending!()

    before = Presence.cohost_session_keys()

    Enum.each(before, fn key ->
      Enum.each(Presence.cohosts(key), fn %{region_id: region, hub_node: hub} ->
        if hub == dead_node do
          put_pending(key, region)
        end
      end)
    end)

    touched = Presence.clear_cohost_node(dead_node) ++ Presence.clear_home_node(dead_node)

    Enum.each(Enum.uniq(touched), fn key ->
      disconnect_local_trunk(key)
      notify_local_clients(key, :edge_down)
    end)

    :ok
  end

  @doc """
  Called when a peer node comes up. If it is a hub for a pending peer region,
  auto `Trunk.reconnect_cohosts/2` when trunk keys are available in env.
  """
  @spec on_peer_hub_up(node()) :: :ok
  def on_peer_hub_up(node) when is_atom(node) do
    ensure_pending!()

    unless Cluster.hub?() do
      :ok
    else
      case peer_region_if_hub(node) do
        {:ok, region} ->
          Enum.each(pending_for_region(region), fn {key, _meta} ->
            case reconnect_opts(key) do
              {:ok, opts} ->
                case Trunk.reconnect_cohosts(key, Keyword.put(opts, :peer_hub_node, node)) do
                  {:ok, _} -> clear_pending(key)
                  {:error, _} -> :ok
                end

              {:error, _} ->
                :ok
            end
          end)

          :ok

        :error ->
          :ok
      end
    end
  end

  @doc """
  Subscribes `pid` to `migrate_required` messages (tests / Control bridges).
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()) when is_pid(pid) do
    ensure_subs!()
    true = :ets.insert(@subscribers, {pid})
    :ok
  end

  @doc """
  Unsubscribes `pid`.
  """
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) when is_pid(pid) do
    ensure_subs!()
    true = :ets.delete(@subscribers, pid)
    :ok
  end

  @doc """
  Builds Placement target and notifies mailbox + Control WS subscribers.
  """
  @spec notify_local_clients({term(), term()}, atom()) :: :ok
  def notify_local_clients({tenant_id, session_id} = key, reason) when is_atom(reason) do
    Presence.init!()

    multi? = Presence.cohosts(key) != [] or reason in [:edge_down, :hub_changed]

    {:ok, place} =
      Placement.recommend(
        tenant_id: tenant_id,
        session_id: session_id,
        multi_home: multi?,
        region_hint: Cluster.local_region(),
        edge_urls: edge_urls()
      )

    event = %{
      type: :migrate_required,
      session_key: key,
      reason: reason,
      target: place
    }

    broadcast(event)
    push_control(tenant_id, session_id, event)
    :ok
  end

  defp push_control(tenant_id, session_id, event) do
    if Code.ensure_loaded?(Xylon.Control.Presence) do
      Xylon.Control.Presence.broadcast_migrate(tenant_id, session_id, event)
    else
      :ok
    end
  end

  defp put_pending(key, region) do
    ensure_pending!()
    true = :ets.insert(@pending, {key, %{peer_region: to_string(region)}})
    :ok
  end

  defp clear_pending(key) do
    ensure_pending!()
    true = :ets.delete(@pending, key)
    :ok
  end

  defp pending_for_region(region) do
    ensure_pending!()
    region_s = to_string(region)

    :ets.tab2list(@pending)
    |> Enum.filter(fn {_key, meta} -> meta.peer_region == region_s end)
  end

  defp peer_region_if_hub(node) do
    try do
      region = :erpc.call(node, Cluster, :local_region, [])
      hub? = :erpc.call(node, Cluster, :hub?, [])

      if hub?, do: {:ok, region}, else: :error
    catch
      _, _ -> :error
    end
  end

  defp reconnect_opts(key) do
    with {:ok, module_id} <- session_module_id(key),
         {:ok, keys} <- trunk_keys_from_env() do
      {:ok, Keyword.merge(keys, module_id: module_id)}
    end
  end

  defp session_module_id(key) do
    case Registry.lookup(Xylon.Registry, key) do
      [{session, _}] ->
        try do
          %{module_id: id} = :sys.get_state(session)
          {:ok, id}
        catch
          _, _ -> {:error, :no_module}
        end

      [] ->
        {:error, :no_session}
    end
  end

  defp trunk_keys_from_env do
    cluster = Application.get_env(:xylon, :cluster, [])

    case Keyword.get(cluster, :trunk_keys) do
      keys when is_list(keys) ->
        {:ok, keys}

      _ ->
        names = ~w(XYLON_TRUNK_KEY_AB XYLON_TRUNK_SALT_AB XYLON_TRUNK_KEY_BA XYLON_TRUNK_SALT_BA)

        if Enum.all?(names, &System.get_env/1) do
          {:ok,
           [
             key_ab: env_bin!("XYLON_TRUNK_KEY_AB"),
             salt_ab: env_bin!("XYLON_TRUNK_SALT_AB"),
             key_ba: env_bin!("XYLON_TRUNK_KEY_BA"),
             salt_ba: env_bin!("XYLON_TRUNK_SALT_BA")
           ]}
        else
          {:error, :missing_trunk_keys}
        end
    end
  end

  defp env_bin!(name) do
    case System.get_env(name) do
      <<"0x", hex::binary>> -> Base.decode16!(hex, case: :mixed)
      bin when is_binary(bin) -> bin
    end
  end

  defp disconnect_local_trunk(key) do
    case Registry.lookup(Xylon.Registry, key) do
      [{session, _}] ->
        _ = Manager.disconnect(session, "trunk")
        :ok

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp broadcast(event) do
    ensure_subs!()

    for {pid} <- :ets.tab2list(@subscribers) do
      send(pid, event)
    end

    :ok
  end

  defp ensure_subs! do
    case :ets.whereis(@subscribers) do
      :undefined ->
        _ = :ets.new(@subscribers, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_pending! do
    case :ets.whereis(@pending) do
      :undefined ->
        _ = :ets.new(@pending, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  end

  defp edge_urls do
    Application.get_env(:xylon, :cluster, [])
    |> Keyword.get(:edge_urls, %{})
  end
end
