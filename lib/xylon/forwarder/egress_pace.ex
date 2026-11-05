defmodule Xylon.Forwarder.EgressPace do
  @moduledoc """
  Egress send timing for SFU video (passthrough).

  ## What problem this solves

  Publisher RTP already carries realtime pacing. Re-clocking subscriber egress
  to a 90 kHz timeline anchored at the SFU's first send **holds** frames that
  arrive even slightly early (common on localhost), adding tens of milliseconds
  that never appear in `[:xylon, :rtp, :forward]` (that probe ends at enqueue).
  This module keeps the paced-queue hook but returns `due == now` so video
  leaves as soon as the SendWorker drains it. `wait_plan/2` remains for any
  future shaping that schedules real delays.

  Audio and non-video payload types are unpaced (`due == now`).

  ## Internal

  Pure helpers for `Xylon.Forwarder.SendWorker` and the Forwarder inline path.

  ## RFCs

  - [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550) (RTP timestamps; not re-clocked here)
  """

  @ms_us 1_000

  @typedoc "Pace map keyed by `{peer_ref, out_ssrc}`."
  @type pace_map :: %{optional({pid(), non_neg_integer()}) => stream()}

  @typedoc """
  Per-stream anchors (retained for API stability / future shaping).

  ## Fields

  - `:anchor_ts` -- RTP timestamp at last (re)anchor
  - `:anchor_us` -- monotonic us when that anchor was sent
  - `:last_ts` -- last sent RTP timestamp
  - `:last_send_us` -- monotonic us of last send
  """
  @type stream :: %{
          anchor_ts: integer(),
          anchor_us: integer(),
          last_ts: integer(),
          last_send_us: integer()
        }

  @typedoc "How long to wait before sending a paced packet."
  @type wait_plan :: :immediate | {:delay_ms, pos_integer()}

  @doc """
  Returns `{due_us, catch_up?, key}` for `packet` toward `peer_ref`.

  Passthrough: `due_us` is always `now_us` (no RTP re-clock hold).
  """
  @spec due_for(pace_map(), pid(), map(), integer()) ::
          {integer(), boolean(), {pid(), non_neg_integer()}}
  def due_for(pace_map, peer_ref, packet, now_us)
      when is_map(pace_map) and is_pid(peer_ref) and is_integer(now_us) do
    key = {peer_ref, rtp_ssrc(packet)}
    {due, catch_up?} = due(Map.get(pace_map, key), packet, now_us)
    {due, catch_up?, key}
  end

  @doc """
  Chooses a wait strategy for `due_us` relative to `now_us`.

  Remainders under 1ms are `:immediate`. Longer waits use floor ms.
  """
  @spec wait_plan(integer(), integer()) :: wait_plan()
  def wait_plan(due_us, now_us) when is_integer(due_us) and is_integer(now_us) do
    remaining = due_us - now_us

    cond do
      remaining < @ms_us ->
        :immediate

      true ->
        {:delay_ms, max(1, div(remaining, @ms_us))}
    end
  end

  @doc "Stores stream state after a packet was sent at `send_us`."
  @spec put_after(pace_map(), {pid(), non_neg_integer()}, map(), integer(), boolean()) ::
          pace_map()
  def put_after(pace_map, key, packet, send_us, catch_up?)
      when is_map(pace_map) and is_integer(send_us) do
    stream = Map.get(pace_map, key)
    Map.put(pace_map, key, after_send(stream, packet, send_us, catch_up?))
  end

  @doc false
  @spec due(stream() | nil, map(), integer()) :: {integer(), boolean()}
  def due(_stream, packet, now_us) do
    if paceable?(packet) do
      # Passthrough: do not hold to an SFU-local RTP timeline.
      {now_us, false}
    else
      {now_us, false}
    end
  end

  @doc false
  @spec after_send(stream() | nil, map(), integer(), boolean()) :: stream()
  def after_send(stream, packet, send_us, catch_up?) do
    ts = rtp_ts(packet)

    if is_nil(stream) or catch_up? do
      %{anchor_ts: ts, anchor_us: send_us, last_ts: ts, last_send_us: send_us}
    else
      %{stream | last_ts: ts, last_send_us: send_us}
    end
  end

  @doc "True for dynamic video payload types that use the paced SendWorker queue."
  @spec paceable?(map()) :: boolean()
  def paceable?(%{payload_type: pt}) when is_integer(pt) and pt >= 96 and pt != 111, do: true
  def paceable?(_), do: false

  defp rtp_ssrc(%{ssrc: ssrc}) when is_integer(ssrc), do: ssrc
  defp rtp_ssrc(_), do: 0

  defp rtp_ts(%{timestamp: ts}) when is_integer(ts), do: ts
  defp rtp_ts(_), do: 0
end
