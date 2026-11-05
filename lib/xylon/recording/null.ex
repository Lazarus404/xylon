defmodule Xylon.Recording.Null do
  @moduledoc """
  No-op recording handler used when no writer is configured.

  ## What problem this solves

  Phase 1 proves Control start/stop and Conference hook call sites without
  touching disk or ffmpeg. Live SFU forwarding must stay unchanged while
  recording is "on"; this module returns immediately from every callback.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon recording tap no-op.
  """

  @behaviour Xylon.Recording.Handler

  alias Xylon.Recording.Ctx

  @impl true
  @doc "Accepts start; returns empty state."
  @spec on_start(Ctx.t(), map()) :: {:ok, map()}
  def on_start(%Ctx{}, _opts), do: {:ok, %{}}

  @impl true
  @doc "Accepts stop; returns an empty manifest."
  @spec on_stop(Ctx.t(), term()) :: {:ok, map()}
  def on_stop(%Ctx{}, _state), do: {:ok, %{}}

  @impl true
  @doc "Ignores publisher RTP; returns state unchanged."
  @spec on_publisher_rtp(Ctx.t(), term(), map(), term()) :: {:ok, term()}
  def on_publisher_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}

  @impl true
  @doc "Ignores mix RTP; returns state unchanged."
  @spec on_mix_rtp(Ctx.t(), term(), map(), term()) :: {:ok, term()}
  def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
end
