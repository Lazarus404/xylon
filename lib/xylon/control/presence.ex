defmodule Xylon.Control.Presence do
  @moduledoc """
  Room presence reads and WebSocket push fanout.

  ## What problem this solves

  Clients joining over Control WebSocket need an immediate roster snapshot and
  live join/leave, talking, feeds, and groups updates. `list/2` reads Membership
  (no duplicate roster). `subscribe/4` registers a WebSocket pid for
  `presence.snapshot`, `presence.diff`, talking, feeds, and groups pushes via
  `{:xylon_control_presence, map}` messages.

  ## Internal

  GenServer manages subscriber ETS and process monitors; REST/gRPC presence
  calls `list/2` directly without subscribing.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """
  use GenServer

  alias Xylon.Control.Membership

  @table :xylon_control_presence_subs

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns participant_id => meta for a session (includes joined_at when recorded)."
  @spec list(term(), term()) :: map()
  def list(tenant_id, session_id) do
    Membership.list(tenant_id, session_id)
    |> Enum.map(fn {id, meta} ->
      {id, public_meta(meta)}
    end)
    |> Map.new()
  end

  @doc "Same map as `list/2` for WS `presence.snapshot` frames."
  @spec snapshot_payload(term(), term()) :: map()
  def snapshot_payload(tenant_id, session_id), do: list(tenant_id, session_id)

  @doc """
  Registers `ws_pid` for room presence pushes (idempotent per participant_id).

  Monitors `ws_pid`; clears the binding on DOWN.
  """
  @spec subscribe(term(), term(), term(), pid()) :: :ok
  def subscribe(tenant_id, session_id, participant_id, ws_pid)
      when is_pid(ws_pid) do
    GenServer.call(__MODULE__, {:subscribe, tenant_id, session_id, participant_id, ws_pid})
  end

  @doc "Removes a presence subscription for `participant_id` in the room."
  @spec unsubscribe(term(), term(), term()) :: :ok
  def unsubscribe(tenant_id, session_id, participant_id) do
    GenServer.call(__MODULE__, {:unsubscribe, tenant_id, session_id, participant_id})
  end

  @doc """
  Broadcasts a presence diff to all room subscribers.

  `diff` keys: `:action` (`:join` | `:leave`), `:participant_id`, and for join
  optionally `:role`, `:joined_at`, `:meta`.
  """
  @spec broadcast_diff(term(), term(), map()) :: :ok
  def broadcast_diff(tenant_id, session_id, diff) when is_map(diff) do
    GenServer.cast(__MODULE__, {:broadcast_diff, tenant_id, session_id, diff})
  end

  @doc """
  Broadcasts a talking edge event to all room subscribers.

  `payload` keys: `:type` (`:talking` | `:stopped_talking`), `:participant_id`,
  optionally `:audio_level_dbov_avg`. No-ops when Presence is not started.
  """
  @spec broadcast_talking(term(), term(), map()) :: :ok
  def broadcast_talking(tenant_id, session_id, payload) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:broadcast_talking, tenant_id, session_id, payload})

      _ ->
        :ok
    end
  end

  @doc """
  Broadcasts a feeds diff to all room subscribers.

  `payload` keys: `:type` (`:feeds_diff`), `:action` (`:published` | `:unpublished`),
  `:participant_id`, `:feed` (`%{streams: [%{mid:, kind:, codec?: ...}]}`).
  No-ops when Presence is not started.
  """
  @spec broadcast_feeds(term(), term(), map()) :: :ok
  def broadcast_feeds(tenant_id, session_id, payload) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:broadcast_feeds, tenant_id, session_id, payload})

      _ ->
        :ok
    end
  end

  @doc """
  Broadcasts `migrate_required` to Control WebSocket subscribers for the room.

  No-ops when Presence is not started.
  """
  @spec broadcast_migrate(term(), term(), map()) :: :ok
  def broadcast_migrate(tenant_id, session_id, payload) when is_map(payload) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:broadcast_migrate, tenant_id, session_id, payload})

      _ ->
        :ok
    end
  end

  @doc """
  Broadcasts a groups diff to all room subscribers.

  `diff` keys: `:action` (`:create` | `:delete` | `:add_member` | `:remove_member`),
  `:group_id`, and for member actions optionally `:participant_id`.
  No-ops when Presence is not started.
  """
  @spec broadcast_groups(term(), term(), map()) :: :ok
  def broadcast_groups(tenant_id, session_id, diff) when is_map(diff) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(pid, {:broadcast_groups, tenant_id, session_id, diff})

      _ ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe, tenant_id, session_id, participant_id, ws_pid}, _from, state) do
    ensure_table()
    key = {tenant_id, session_id}
    state = demonitor_existing(state, key, participant_id)

    ref = Process.monitor(ws_pid)
    subs = lookup_subs_map(key)
    entry = %{pid: ws_pid, ref: ref}
    true = :ets.insert(@table, {key, Map.put(subs, participant_id, entry)})

    monitors = Map.put(state.monitors, ref, {key, participant_id})
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:unsubscribe, tenant_id, session_id, participant_id}, _from, state) do
    key = {tenant_id, session_id}
    state = demonitor_existing(state, key, participant_id)
    delete_sub(key, participant_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:broadcast_diff, tenant_id, session_id, diff}, state) do
    key = {tenant_id, session_id}
    payload = diff_payload(diff)

    Enum.each(lookup_subs_map(key), fn {_id, %{pid: pid}} ->
      send(pid, {:xylon_control_presence, payload})
    end)

    {:noreply, state}
  end

  def handle_cast({:broadcast_talking, tenant_id, session_id, payload}, state) do
    key = {tenant_id, session_id}
    msg = talking_payload(payload)

    Enum.each(lookup_subs_map(key), fn {_id, %{pid: pid}} ->
      send(pid, {:xylon_control_presence, msg})
    end)

    {:noreply, state}
  end

  def handle_cast({:broadcast_feeds, tenant_id, session_id, payload}, state) do
    key = {tenant_id, session_id}
    msg = feeds_payload(payload)

    Enum.each(lookup_subs_map(key), fn {_id, %{pid: pid}} ->
      send(pid, {:xylon_control_presence, msg})
    end)

    {:noreply, state}
  end

  def handle_cast({:broadcast_migrate, tenant_id, session_id, payload}, state) do
    key = {tenant_id, session_id}
    msg = migrate_payload(payload)

    Enum.each(lookup_subs_map(key), fn {_id, %{pid: pid}} ->
      send(pid, {:xylon_control_presence, msg})
    end)

    {:noreply, state}
  end

  def handle_cast({:broadcast_groups, tenant_id, session_id, diff}, state) do
    key = {tenant_id, session_id}
    msg = groups_payload(diff)

    Enum.each(lookup_subs_map(key), fn {_id, %{pid: pid}} ->
      send(pid, {:xylon_control_presence, msg})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{key, participant_id}, monitors} ->
        delete_sub(key, participant_id)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  defp lookup_subs_map(key) do
    case :ets.lookup(@table, key) do
      [{^key, map}] when is_map(map) -> map
      _ -> %{}
    end
  end

  defp delete_sub(key, participant_id) do
    case :ets.lookup(@table, key) do
      [{^key, map}] ->
        map = Map.delete(map, participant_id)

        if map == %{} do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, map})
        end

      _ ->
        :ok
    end
  end

  defp demonitor_existing(state, key, participant_id) do
    case lookup_subs_map(key) do
      %{^participant_id => %{ref: ref}} ->
        Process.demonitor(ref, [:flush])
        monitors = Map.delete(state.monitors, ref)
        delete_sub(key, participant_id)
        %{state | monitors: monitors}

      _ ->
        state
    end
  end

  defp diff_payload(diff) do
    action = Map.fetch!(diff, :action)
    participant_id = Map.fetch!(diff, :participant_id)

    base = %{type: :diff, action: action, participant_id: participant_id}

    case action do
      :join ->
        base
        |> maybe_put(:role, Map.get(diff, :role))
        |> maybe_put(:joined_at, Map.get(diff, :joined_at))
        |> Map.put(:meta, Map.get(diff, :meta) || %{})

      :leave ->
        base

      _ ->
        base
    end
  end

  defp talking_payload(payload) do
    type = Map.fetch!(payload, :type)
    participant_id = Map.fetch!(payload, :participant_id)

    %{type: type, participant_id: participant_id}
    |> maybe_put(:audio_level_dbov_avg, Map.get(payload, :audio_level_dbov_avg))
  end

  defp feeds_payload(payload) do
    feed = Map.get(payload, :feed) || %{streams: []}
    streams = Map.get(feed, :streams, [])

    %{
      type: :feeds_diff,
      action: Map.fetch!(payload, :action),
      participant_id: Map.fetch!(payload, :participant_id),
      streams: Enum.map(streams, &public_stream/1)
    }
  end

  defp migrate_payload(payload) do
    target = Map.get(payload, :target) || %{}

    %{
      type: :migrate_required,
      reason: Map.get(payload, :reason, :edge_down),
      session_key: Map.get(payload, :session_key),
      target: %{
        edge_url: Map.get(target, :edge_url),
        node: target_node(Map.get(target, :node)),
        region_id: Map.get(target, :region_id),
        role: Map.get(target, :role)
      }
    }
  end

  defp groups_payload(diff) do
    action = Map.fetch!(diff, :action)
    group_id = Map.fetch!(diff, :group_id)

    %{type: :groups_diff, action: action, group_id: group_id}
    |> maybe_put(:participant_id, Map.get(diff, :participant_id))
  end

  defp target_node(node) when is_atom(node), do: Atom.to_string(node)
  defp target_node(node) when is_binary(node), do: node
  defp target_node(_), do: nil

  defp public_stream(%{mid: mid, kind: kind} = stream) do
    %{mid: mid, kind: Atom.to_string(kind)}
    |> maybe_put(:codec, Map.get(stream, :codec))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp public_meta(meta) when is_map(meta) do
    %{
      "role" => Map.get(meta, :role) || Map.get(meta, "role"),
      "joined_at" => Map.get(meta, :joined_at) || Map.get(meta, "joined_at"),
      "meta" => Map.drop(meta, [:role, :joined_at, "role", "joined_at"])
    }
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        @table
    end
  end
end
