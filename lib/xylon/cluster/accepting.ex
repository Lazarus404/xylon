defmodule Xylon.Cluster.Accepting do
  @moduledoc """
  Per-node flag for whether this edge accepts new sessions.

  ## What problem this solves

  Scalers drain a node before stopping it: set `accepting` false so placement
  and new `Session.create/4` skip this edge while existing rooms empty out.
  State is local ETS (Presence-style), readable by peers via `:erpc`.

  ## RFCs

  None.
  """

  @table :xylon_cluster_accepting
  @key :local
  @erpc_timeout_ms 2_000

  @doc """
  Creates the accepting ETS table if missing.
  """
  @spec init!() :: :ok
  def init! do
    case :ets.whereis(@table) do
      :undefined ->
        _ =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Clears local accepting state (tests). Default accepting is true when empty.
  """
  @spec reset!() :: :ok
  def reset! do
    init!()
    true = :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  True when this node accepts new sessions (default true).
  """
  @spec accepting?() :: boolean()
  def accepting? do
    init!()

    case :ets.lookup(@table, @key) do
      [{_, false}] -> false
      _ -> true
    end
  end

  @doc """
  Sets whether this node accepts new sessions.
  """
  @spec set(boolean()) :: :ok
  def set(flag) when is_boolean(flag) do
    init!()
    true = :ets.insert(@table, {@key, flag})
    :ok
  end

  @doc """
  True when `node` accepts new sessions (local or `:erpc`; unknown/fail -> false).
  """
  @spec accepting_on?(node()) :: boolean()
  def accepting_on?(node) when is_atom(node) do
    if node == Node.self() do
      accepting?()
    else
      try do
        :erpc.call(node, __MODULE__, :accepting?, [], @erpc_timeout_ms) == true
      catch
        :exit, _ -> false
        :error, _ -> false
        :throw, _ -> false
      end
    end
  end

  @doc """
  Sets accepting on `node` (local or `:erpc`).
  """
  @spec set_on(node(), boolean()) :: :ok | {:error, term()}
  def set_on(node, flag) when is_atom(node) and is_boolean(flag) do
    if node == Node.self() do
      set(flag)
    else
      try do
        :ok = :erpc.call(node, __MODULE__, :set, [flag], @erpc_timeout_ms)
        :ok
      catch
        :exit, reason -> {:error, reason}
        :error, reason -> {:error, reason}
        :throw, reason -> {:error, reason}
      end
    end
  end
end
