defmodule Xylon.Recording.LayoutSink do
  @moduledoc """
  ETS registry for the live layout GenServer (Plan `:record` sink).

  ## What problem this solves

  Forwarder must deliver rewritten RTP to the layout compositor without linking
  Xylon to a concrete recorder module. The layout worker registers under
  `plan_ref` (Session pid); Forwarder calls `ingest/2` which casts when present.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon Phase 8 layout sink registry.
  """

  @table :xylon_recording_layout

  @doc "Ensures the layout sink ETS table exists."
  @spec ensure_table!() :: :ok
  def ensure_table! do
    _ = ensure_table()
    :ok
  end

  @doc "Registers `layout_pid` as the sink for `plan_ref`."
  @spec register(term(), pid()) :: :ok
  def register(plan_ref, layout_pid) when is_pid(layout_pid) do
    ensure_table()
    true = :ets.insert(@table, {plan_ref, layout_pid})
    :ok
  end

  @doc "Removes the sink registration for `plan_ref`."
  @spec unregister(term()) :: :ok
  def unregister(plan_ref) do
    ensure_table()
    true = :ets.delete(@table, plan_ref)
    :ok
  end

  @doc """
  Enqueues one rewritten RTP packet for the layout worker.

  `dest` is `%{type: :record, plan_ref, publisher_id, mid, kind, codec}`.
  No-op when no layout is registered. Never raises.
  """
  @spec ingest(map(), term()) :: :ok
  def ingest(%{type: :record, plan_ref: plan_ref} = dest, rtp) do
    ensure_table()

    case :ets.lookup(@table, plan_ref) do
      [{^plan_ref, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          send(pid, {:layout_rtp, dest, rtp})
        end

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def ingest(_, _), do: :ok

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
