defmodule Xylon.Control.Webhooks do
  @moduledoc """
  Fire-and-forget webhook emit for Control lifecycle events.

  ## What problem this solves

  Inject, quota, moderation, session, and recording paths must notify tenant
  backends without blocking media or HTTP handlers on remote HTTP latency.
  `emit/2` schedules async delivery via `Webhooks.Queue` (DETS DLQ on failure).
  Always returns `:ok` to callers.

  Common `type` values: `session.created`, `session.closed`,
  `participant.joined`, `participant.left`, `inject.accepted`,
  `inject.rejected`, `quota.exceeded`, `recording.completed`,
  `recording.failed`.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane webhook envelope (JSON POST).
  """

  alias Xylon.Control.Webhooks.Queue

  @doc """
  Emits a webhook event asynchronously.

  No-op when `webhook_url` is unset. Always returns `:ok` to the caller.
  """
  @spec emit(binary(), map()) :: :ok
  def emit(type, payload \\ %{}) when is_binary(type) and is_map(payload) do
    Queue.deliver_async(type, payload)
  end
end
