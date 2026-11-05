defmodule Xylon.Recording.Registry do
  @moduledoc """
  ETS gate for active recordings on the media hot path.

  ## What problem this solves

  Conference `handle_rtp/3` must know if a Session is recording without calling
  the Session GenServer (that would block live forwarding). Session writes an
  entry on start/stop; Conference reads and may update opaque handler state
  after each RTP callback.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon recording hot-path registry.

  ## Internal

  Keyed by `plan_ref` (Session pid for conference).   Entry:
  `{handler_mod, ctx, handler_state, had_local_publishers?}`.
  """

  alias Xylon.Recording.Ctx

  @table :xylon_recording

  @typedoc "Active recording registry entry."
  @type entry :: {module(), Ctx.t(), term()}

  @doc "Ensures the named ETS table exists (idempotent)."
  @spec ensure_table!() :: :ok
  def ensure_table! do
    _ = ensure_table()
    :ok
  end

  @doc "Stores an active recording for `plan_ref`."
  @spec put(term(), entry()) :: :ok
  def put(plan_ref, {mod, %Ctx{} = ctx, state} = _entry)
      when is_atom(mod) do
    ensure_table()
    true = :ets.insert(@table, {plan_ref, mod, ctx, state, false})
    :ok
  end

  @doc "Returns the active entry for `plan_ref`, or `nil`."
  @spec get(term()) :: entry() | nil
  def get(plan_ref) do
    ensure_table()

    case :ets.lookup(@table, plan_ref) do
      [{^plan_ref, mod, ctx, state, _had_local}] -> {mod, ctx, state}
      [{^plan_ref, mod, ctx, state}] -> {mod, ctx, state}
      [] -> nil
    end
  end

  @doc "Updates only the opaque handler state for an active entry."
  @spec update_state(term(), term()) :: :ok
  def update_state(plan_ref, new_state) do
    ensure_table()
    _ = :ets.update_element(@table, plan_ref, {4, new_state})
    :ok
  end

  @doc """
  Marks that this edge saw at least one local (non-trunk) publisher RTP.

  Used for multi-home expected-edge semantics (idle edges vs capture edges).
  """
  @spec mark_local_publisher(term()) :: :ok
  def mark_local_publisher(plan_ref) do
    ensure_table()
    _ = :ets.update_element(@table, plan_ref, {5, true})
    :ok
  end

  @doc "Returns whether local publisher RTP was seen for `plan_ref`."
  @spec had_local_publishers?(term()) :: boolean()
  def had_local_publishers?(plan_ref) do
    ensure_table()

    case :ets.lookup(@table, plan_ref) do
      [{^plan_ref, _, _, _, true}] -> true
      _ -> false
    end
  end

  @doc "Removes the entry for `plan_ref` and returns it, or `nil`."
  @spec take(term()) :: entry() | nil
  def take(plan_ref) do
    ensure_table()

    case :ets.take(@table, plan_ref) do
      [{^plan_ref, mod, ctx, state, _had_local}] -> {mod, ctx, state}
      [{^plan_ref, mod, ctx, state}] -> {mod, ctx, state}
      [] -> nil
    end
  end

  @doc """
  Like `take/1`, also returning whether local publisher RTP was seen.
  """
  @spec take_with_local(term()) :: {entry(), boolean()} | nil
  def take_with_local(plan_ref) do
    ensure_table()

    case :ets.take(@table, plan_ref) do
      [{^plan_ref, mod, ctx, state, had_local}] -> {{mod, ctx, state}, had_local == true}
      [{^plan_ref, mod, ctx, state}] -> {{mod, ctx, state}, false}
      [] -> nil
    end
  end

  @doc "Deletes the entry for `plan_ref` if present."
  @spec delete(term()) :: :ok
  def delete(plan_ref) do
    ensure_table()
    true = :ets.delete(@table, plan_ref)
    :ok
  end

  @doc """
  Invokes `on_publisher_rtp/4` when a recording is active for `plan_ref`.

  Swallows handler errors so the live path never crashes. Updates handler state
  on success.
  """
  @spec maybe_publisher_rtp(term(), map(), term()) :: :ok
  def maybe_publisher_rtp(plan_ref, meta, rtp) when is_map(meta) do
    case get(plan_ref) do
      nil ->
        :ok

      {mod, ctx, state} ->
        maybe_mark_local(plan_ref, meta)

        try do
          case mod.on_publisher_rtp(ctx, state, meta, rtp) do
            {:ok, new_state} -> update_state(plan_ref, new_state)
            _ -> :ok
          end
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
    end
  end

  @doc """
  Invokes `on_mix_rtp/4` when active recording mode is `:tracks_and_mix`.

  Swallows handler errors. No-op when mode is `:tracks` or no recording.
  """
  @spec maybe_mix_rtp(term(), map(), term()) :: :ok
  def maybe_mix_rtp(plan_ref, meta, rtp) when is_map(meta) do
    case get(plan_ref) do
      {mod, %Ctx{mode: :tracks_and_mix} = ctx, state} ->
        # MCU mix stem is hub-local capture.
        mark_local_publisher(plan_ref)

        try do
          case mod.on_mix_rtp(ctx, state, meta, rtp) do
            {:ok, new_state} -> update_state(plan_ref, new_state)
            _ -> :ok
          end
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_mark_local(plan_ref, meta) do
    via = Map.get(meta, :via) || Map.get(meta, "via")

    if via != "trunk" do
      mark_local_publisher(plan_ref)
    else
      :ok
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

      _ ->
        @table
    end
  end
end
