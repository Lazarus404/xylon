defmodule Xylon.Control.Groups do
  @moduledoc """
  Named participant groups for Control destination resolution.

  ## What problem this solves

  Apps need mutable named sets (breakouts, teams) without putting role/group
  filters on the media path. Groups stores `{tenant, session, group_id}` ->
  participant id sets in ETS, exposes CRUD, and cleans members on leave.
  `Dest.resolve` turns `{"group": id}` into id lists for inject/publish.

  ## Internal

  Started with Control when enabled. Public mutate/read APIs are safe from any
  process; the GenServer exists for supervision. Diffs fan out via Presence
  subscribers as `groups.diff` frames.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  alias Xylon.Control.Membership

  @table :xylon_control_groups
  @by_pid :xylon_control_groups_by_pid

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates an empty group. Returns `{:error, :already_exists}` when present.
  """
  @spec create(term(), term(), binary()) :: :ok | {:error, :already_exists | :bad_group_id}
  def create(tenant_id, session_id, group_id) do
    with {:ok, gid} <- normalize_group_id(group_id) do
      ensure_tables()
      key = {tenant_id, session_id, gid}

      case :ets.lookup(@table, key) do
        [{^key, _}] ->
          {:error, :already_exists}

        [] ->
          true = :ets.insert(@table, {key, MapSet.new()})
          broadcast(tenant_id, session_id, %{action: :create, group_id: gid})
          :ok
      end
    end
  end

  @doc "Deletes a group and reverse-index entries. Missing group is `:not_found`."
  @spec delete(term(), term(), binary()) :: :ok | {:error, :not_found | :bad_group_id}
  def delete(tenant_id, session_id, group_id) do
    with {:ok, gid} <- normalize_group_id(group_id) do
      ensure_tables()
      key = {tenant_id, session_id, gid}

      case :ets.lookup(@table, key) do
        [{^key, members}] ->
          Enum.each(MapSet.to_list(members), fn pid ->
            drop_reverse(tenant_id, session_id, pid, gid)
          end)

          :ets.delete(@table, key)
          broadcast(tenant_id, session_id, %{action: :delete, group_id: gid})
          :ok

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Adds a session member to a group.

  Returns `:not_found` when the group is missing, `:not_in_session` when the
  participant is not in Membership.
  """
  @spec add_member(term(), term(), binary(), term()) ::
          :ok | {:error, :not_found | :not_in_session | :bad_group_id}
  def add_member(tenant_id, session_id, group_id, participant_id) do
    with {:ok, gid} <- normalize_group_id(group_id) do
      ensure_tables()

      unless Map.has_key?(Membership.list(tenant_id, session_id), participant_id) do
        {:error, :not_in_session}
      else
        key = {tenant_id, session_id, gid}

        case :ets.lookup(@table, key) do
          [{^key, members}] ->
            if MapSet.member?(members, participant_id) do
              :ok
            else
              true = :ets.insert(@table, {key, MapSet.put(members, participant_id)})
              put_reverse(tenant_id, session_id, participant_id, gid)

              broadcast(tenant_id, session_id, %{
                action: :add_member,
                group_id: gid,
                participant_id: participant_id
              })

              :ok
            end

          [] ->
            {:error, :not_found}
        end
      end
    end
  end

  @doc "Removes a member from a group. Missing group is `:not_found`."
  @spec remove_member(term(), term(), binary(), term()) ::
          :ok | {:error, :not_found | :bad_group_id}
  def remove_member(tenant_id, session_id, group_id, participant_id) do
    with {:ok, gid} <- normalize_group_id(group_id) do
      ensure_tables()
      key = {tenant_id, session_id, gid}

      case :ets.lookup(@table, key) do
        [{^key, members}] ->
          if MapSet.member?(members, participant_id) do
            true = :ets.insert(@table, {key, MapSet.delete(members, participant_id)})
            drop_reverse(tenant_id, session_id, participant_id, gid)

            broadcast(tenant_id, session_id, %{
              action: :remove_member,
              group_id: gid,
              participant_id: participant_id
            })

            :ok
          else
            :ok
          end

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc "Participant ids currently listed in the group (may include stale until leave)."
  @spec members(term(), term(), binary()) :: [term()]
  def members(tenant_id, session_id, group_id) do
    case normalize_group_id(group_id) do
      {:ok, gid} ->
        ensure_tables()

        case :ets.lookup(@table, {tenant_id, session_id, gid}) do
          [{_, set}] -> MapSet.to_list(set)
          [] -> []
        end

      {:error, _} ->
        []
    end
  end

  @doc "Returns `%{group_id => [participant_id]}` for the session."
  @spec list(term(), term()) :: %{optional(binary()) => [term()]}
  def list(tenant_id, session_id) do
    ensure_tables()

    @table
    |> :ets.match({{tenant_id, session_id, :"$1"}, :"$2"})
    |> Map.new(fn [gid, set] -> {gid, MapSet.to_list(set)} end)
  end

  @doc "Same as `list/2` for WS `groups.snapshot` frames."
  @spec snapshot_payload(term(), term()) :: %{optional(binary()) => [term()]}
  def snapshot_payload(tenant_id, session_id), do: list(tenant_id, session_id)

  @doc "Removes `participant_id` from every group in the session (leave path)."
  @spec remove_participant(term(), term(), term()) :: :ok
  def remove_participant(tenant_id, session_id, participant_id) do
    ensure_tables()
    rkey = {tenant_id, session_id, participant_id}

    group_ids =
      case :ets.lookup(@by_pid, rkey) do
        [{^rkey, set}] -> MapSet.to_list(set)
        [] -> []
      end

    Enum.each(group_ids, fn gid ->
      key = {tenant_id, session_id, gid}

      case :ets.lookup(@table, key) do
        [{^key, members}] ->
          true = :ets.insert(@table, {key, MapSet.delete(members, participant_id)})

          broadcast(tenant_id, session_id, %{
            action: :remove_member,
            group_id: gid,
            participant_id: participant_id
          })

        [] ->
          :ok
      end
    end)

    :ets.delete(@by_pid, rkey)
    :ok
  end

  @doc "Clears all groups for a session."
  @spec clear(term(), term()) :: :ok
  def clear(tenant_id, session_id) do
    ensure_tables()
    :ets.match_delete(@table, {{tenant_id, session_id, :_}, :_})
    :ets.match_delete(@by_pid, {{tenant_id, session_id, :_}, :_})
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_tables()
    {:ok, %{}}
  end

  defp normalize_group_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp normalize_group_id(_), do: {:error, :bad_group_id}

  defp put_reverse(tenant_id, session_id, participant_id, gid) do
    rkey = {tenant_id, session_id, participant_id}

    set =
      case :ets.lookup(@by_pid, rkey) do
        [{^rkey, s}] -> MapSet.put(s, gid)
        [] -> MapSet.new([gid])
      end

    true = :ets.insert(@by_pid, {rkey, set})
  end

  defp drop_reverse(tenant_id, session_id, participant_id, gid) do
    rkey = {tenant_id, session_id, participant_id}

    case :ets.lookup(@by_pid, rkey) do
      [{^rkey, set}] ->
        set = MapSet.delete(set, gid)

        if MapSet.size(set) == 0 do
          :ets.delete(@by_pid, rkey)
        else
          :ets.insert(@by_pid, {rkey, set})
        end

      [] ->
        :ok
    end
  end

  defp broadcast(tenant_id, session_id, diff) do
    if Code.ensure_loaded?(Xylon.Control.Presence) and
         function_exported?(Xylon.Control.Presence, :broadcast_groups, 3) do
      Xylon.Control.Presence.broadcast_groups(tenant_id, session_id, diff)
    end

    :ok
  end

  defp ensure_tables do
    ensure_table(@table)
    ensure_table(@by_pid)
  end

  defp ensure_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        name
    end
  end
end
