defmodule Xylon.Control.Membership do
  @moduledoc """
  In-memory session roster for Control targeting and presence.

  ## What problem this solves

  Inject `dest` filters and presence snapshots need a fast view of who is in
  each room. Membership maintains an ETS map of participant id to metadata,
  updated on Session join/leave. Keyed by `{tenant_id, session_id}`.

  ## Internal

  Started with Control when enabled. Public `join/4`, `leave/3`, `list/2`, and
  `ids/2` are safe from any process; the GenServer exists for supervision only.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  @table :xylon_control_membership

  @type meta :: %{optional(atom()) => term()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records a participant join (idempotent upsert)."
  @spec join(term(), term(), term(), meta()) :: :ok
  def join(tenant_id, session_id, participant_id, meta \\ %{}) do
    ensure_table()
    key = {tenant_id, session_id}

    members =
      case :ets.lookup(@table, key) do
        [{^key, map}] -> Map.put(map, participant_id, normalize_meta(meta))
        [] -> %{participant_id => normalize_meta(meta)}
      end

    true = :ets.insert(@table, {key, members})
    :ok
  end

  @doc "Removes a participant; deletes the session row when empty."
  @spec leave(term(), term(), term()) :: :ok
  def leave(tenant_id, session_id, participant_id) do
    ensure_table()
    key = {tenant_id, session_id}

    case :ets.lookup(@table, key) do
      [{^key, map}] ->
        map = Map.delete(map, participant_id)

        if map == %{} do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, map})
        end

        :ok

      [] ->
        :ok
    end
  end

  @doc "Clears all membership for a session."
  @spec clear(term(), term()) :: :ok
  def clear(tenant_id, session_id) do
    ensure_table()
    :ets.delete(@table, {tenant_id, session_id})
    :ok
  end

  @doc "Returns participant_id => meta map for a session."
  @spec list(term(), term()) :: %{optional(term()) => meta()}
  def list(tenant_id, session_id) do
    ensure_table()

    case :ets.lookup(@table, {tenant_id, session_id}) do
      [{_, map}] -> map
      [] -> %{}
    end
  end

  @doc "All participant ids currently in the session."
  @spec ids(term(), term()) :: [term()]
  def ids(tenant_id, session_id), do: Map.keys(list(tenant_id, session_id))

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
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

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}
end
