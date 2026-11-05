defmodule Xylon.Control.Moderation do
  @moduledoc """
  Per-participant mute and ban flags for Control and Session gates.

  ## What problem this solves

  Hosts must stop abusive inject or media without tearing down the room.
  Moderation stores ETS flags per `{tenant_id, session_id, participant_id}`.
  Mute blocks inject (and optionally pauses outbound A/V via Session). Ban
  blocks inject and join/offer. Actions append to `Audit`.

  ## Internal

  GenServer owns the moderation ETS table; flags are read synchronously.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  use GenServer

  alias Xylon.Control.Audit

  @table :xylon_control_moderation

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Applies mute/unmute/ban/unban and appends an audit row."
  @spec set(term(), term(), term(), :mute | :unmute | :ban | :unban, keyword()) ::
          :ok | {:error, :bad_action}
  def set(tenant_id, session_id, participant_id, action, opts \\ [])

  def set(tenant_id, session_id, participant_id, action, opts)
      when action in [:mute, :unmute, :ban, :unban] do
    ensure_table()
    key = {tenant_id, session_id, participant_id}
    flags = current_flags(key)

    flags =
      case action do
        :mute -> Map.put(flags, :muted, true)
        :unmute -> Map.put(flags, :muted, false)
        :ban -> Map.put(flags, :banned, true)
        :unban -> Map.put(flags, :banned, false)
      end

    if flags[:muted] != true and flags[:banned] != true do
      :ets.delete(@table, key)
    else
      :ets.insert(@table, {key, flags})
    end

    if Code.ensure_loaded?(Audit) do
      Audit.append(tenant_id, session_id, %{
        action: action,
        target: participant_id,
        actor: Keyword.get(opts, :actor),
        reason: Keyword.get(opts, :reason)
      })
    end

    :ok
  end

  def set(_, _, _, _, _), do: {:error, :bad_action}

  @doc "True when participant may not inject (muted or banned)."
  @spec blocked_inject?(term(), term(), term()) :: boolean()
  def blocked_inject?(tenant_id, session_id, participant_id) do
    flags = current_flags({tenant_id, session_id, participant_id})
    flags[:muted] == true or flags[:banned] == true
  end

  @doc "True when participant may not join/offer (banned)."
  @spec blocked_join?(term(), term(), term()) :: boolean()
  def blocked_join?(tenant_id, session_id, participant_id) do
    current_flags({tenant_id, session_id, participant_id})[:banned] == true
  end

  @doc "Test helper."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp current_flags(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, flags}] -> flags
      [] -> %{}
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
