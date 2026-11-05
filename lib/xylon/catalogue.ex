defmodule Xylon.Catalogue do
  @moduledoc """
  In-memory registry of attached backend modules.

  ## What problem this solves

  Sessions are started with a catalogue id (e.g. `:echo`, `:conference`). This
  module maps that atom to the Elixir module implementing `Xylon.Backend`.
  Registration happens at boot via `config :xylon, :backends` and at runtime
  via `Xylon.attach/1`.

  **Internal:** backed by a public ETS table (`:xylon_catalogue`). Prefer
  `Xylon.attach/1` and `Xylon.attached?/1` from application code.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon backend catalogue (application configuration).
  """

  @table :xylon_catalogue

  @doc """
  Creates the catalogue ETS table if missing.

  Idempotent; called from `Xylon.Application` and `put/2`.
  """
  @spec init() :: :ok
  def init do
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

      _tid ->
        :ok
    end
  end

  @doc """
  Registers backend `module` under catalogue atom `id`.

  Overwrites any previous entry for the same `id`.
  """
  @spec put(atom(), module()) :: :ok
  def put(id, module) when is_atom(id) and is_atom(module) do
    init()
    true = :ets.insert(@table, {id, module})
    :ok
  end

  @doc """
  Looks up the module registered as `id`.

  Returns `{:ok, module}` or `:error` when not attached.
  """
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(id) when is_atom(id) do
    init()

    case :ets.lookup(@table, id) do
      [{^id, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Deletes all catalogue entries.

  Intended for ExUnit tests; not used in production boot.
  """
  @spec reset!() :: :ok
  def reset! do
    init()
    true = :ets.delete_all_objects(@table)
    :ok
  end
end
