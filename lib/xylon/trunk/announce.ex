defmodule Xylon.Trunk.Announce do
  @moduledoc """
  Control-plane metadata for remote participants and tracks across edges.

  ## What problem this solves

  Multi-home edges must learn which publishers and datachannel labels exist on
  the far edge without sending media over Distributed Erlang. This module
  encodes that membership/track announcement for `Xylon.Trunk.Manager`.

  ## RFCs

  None; announcements are Xylon control messages only.
  """

  @typedoc """
  One remote track for Plan install on the receiving edge.

  ## Fields

  * `:publisher_id` - Far participant id (stable across hops)
  * `:mid` - SDP mid string
  * `:ssrc` - Inbound SSRC expected on the trunk pipe for this track
  * `:kind` - `:audio` | `:video` | `:application`
  """
  @type track :: %{
          publisher_id: term(),
          mid: binary(),
          ssrc: non_neg_integer(),
          kind: :audio | :video | :application
        }

  @typedoc """
  Announcement payload.

  ## Fields

  * `:session_key` - `{tenant_id, session_id}` logical room
  * `:from_edge` - atom or binary edge id
  * `:participants` - list of `%{id: term(), role: atom(), labels: [binary()]}`
  * `:tracks` - list of `track()`
  """
  @type t :: %{
          session_key: {term(), term()},
          from_edge: term(),
          participants: [map()],
          tracks: [track()]
        }

  @doc """
  Builds an announcement map.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %{
      session_key: Keyword.fetch!(opts, :session_key),
      from_edge: Keyword.get(opts, :from_edge, :edge),
      participants: Keyword.get(opts, :participants, []),
      tracks: Keyword.get(opts, :tracks, [])
    }
  end

  @doc """
  Validates a received announcement.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%{
        session_key: {_, _},
        from_edge: _,
        participants: participants,
        tracks: tracks
      })
      when is_list(participants) and is_list(tracks),
      do: true

  def valid?(_), do: false
end
