defmodule Xylon.Recording do
  @moduledoc """
  Application-env entry for the pluggable room recording handler.

  ## What problem this solves

  Recording writers are optional add-ons. Xylon reads one handler module from
  `config :xylon, :recording` (default `Xylon.Recording.Null`) so Control and
  Conference share the same tap without hard-coding a disk writer.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon recording configuration.
  """

  alias Xylon.Recording.Null

  @doc """
  Returns the configured recording handler module.

  Reads `Application.get_env(:xylon, :recording, [])` key `:handler`.
  Defaults to `Xylon.Recording.Null`.
  """
  @spec handler() :: module()
  def handler do
    Keyword.get(config(), :handler, Null)
  end

  @doc "Recording application env keyword list."
  @spec config() :: keyword()
  def config do
    case Application.get_env(:xylon, :recording, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
