defmodule Xylon.Control.Feeds do
  @moduledoc """
  Active A/V publisher index per session (Janus `publishers[]` analogue).

  ## What problem this solves

  Join/leave presence is not the same as who is publishing audio or video.
  Feeds tracks active publisher metadata (streams by SDP mid) separately from
  Membership, keyed by `{tenant_id, session_id}`. Upserts and deletes broadcast
  `feeds.diff` via `Presence.broadcast_feeds/3` to subscribed WebSockets.

  ## Internal

  ETS-backed GenServer; Session/backend code calls `put/4` and `delete/3`.

  ## RFCs

  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) (codec names via XSDP/XGW)
  - [RFC 5888](https://www.rfc-editor.org/rfc/rfc5888) (SDP mid on each stream)
  """

  use GenServer

  alias Xylon.Control.Presence

  @table :xylon_control_feeds

  @typedoc "One published stream in a feed."
  @type stream :: %{
          required(:mid) => binary(),
          required(:kind) => :audio | :video,
          optional(:codec) => binary()
        }

  @typedoc "Publisher feed: one entry per published participant."
  @type feed :: %{
          required(:streams) => [stream()]
        }

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Upserts a publisher feed and broadcasts `feeds.diff` published."
  @spec put(term(), term(), term(), feed()) :: :ok
  def put(tenant_id, session_id, participant_id, feed) when is_map(feed) do
    ensure_table()
    key = {tenant_id, session_id}
    normalized = normalize_feed(feed)

    feeds =
      case :ets.lookup(@table, key) do
        [{^key, map}] -> Map.put(map, participant_id, normalized)
        [] -> %{participant_id => normalized}
      end

    true = :ets.insert(@table, {key, feeds})

    _ =
      Presence.broadcast_feeds(tenant_id, session_id, %{
        type: :feeds_diff,
        action: :published,
        participant_id: participant_id,
        feed: normalized
      })

    :ok
  end

  @doc "Removes a publisher feed and broadcasts unpublished when it existed."
  @spec delete(term(), term(), term()) :: :ok
  def delete(tenant_id, session_id, participant_id) do
    ensure_table()
    key = {tenant_id, session_id}

    case :ets.lookup(@table, key) do
      [{^key, map}] ->
        case Map.pop(map, participant_id) do
          {nil, _} ->
            :ok

          {feed, map} ->
            if map == %{} do
              :ets.delete(@table, key)
            else
              :ets.insert(@table, {key, map})
            end

            _ =
              Presence.broadcast_feeds(tenant_id, session_id, %{
                type: :feeds_diff,
                action: :unpublished,
                participant_id: participant_id,
                feed: feed
              })

            :ok
        end

      [] ->
        :ok
    end
  end

  @doc "Clears all feeds for a session (no per-publisher broadcast)."
  @spec clear(term(), term()) :: :ok
  def clear(tenant_id, session_id) do
    ensure_table()
    :ets.delete(@table, {tenant_id, session_id})
    :ok
  end

  @doc "Returns publisher maps for WS snapshot (string kinds on each stream)."
  @spec list(term(), term()) :: [map()]
  def list(tenant_id, session_id) do
    ensure_table()

    case :ets.lookup(@table, {tenant_id, session_id}) do
      [{_, map}] ->
        map
        |> Enum.map(fn {id, feed} -> public_feed(id, feed) end)
        |> Enum.sort_by(& &1.participant_id)

      [] ->
        []
    end
  end

  @doc "Same as `list/2` for `feeds.snapshot` frames."
  @spec snapshot_payload(term(), term()) :: [map()]
  def snapshot_payload(tenant_id, session_id), do: list(tenant_id, session_id)

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp normalize_feed(feed) do
    streams =
      feed
      |> Map.get(:streams, [])
      |> Enum.map(&normalize_stream/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.mid)
      |> Enum.sort_by(& &1.mid)

    %{streams: streams}
  end

  defp normalize_stream(%{mid: mid, kind: kind} = stream)
       when is_binary(mid) and mid != "" and kind in [:audio, :video] do
    base = %{mid: mid, kind: kind}

    case Map.get(stream, :codec) do
      codec when is_binary(codec) and codec != "" -> Map.put(base, :codec, codec)
      _ -> base
    end
  end

  defp normalize_stream(_), do: nil

  defp public_feed(participant_id, feed) do
    %{
      participant_id: participant_id,
      streams: Enum.map(feed.streams, &public_stream/1)
    }
  end

  defp public_stream(%{mid: mid, kind: kind} = stream) do
    %{mid: mid, kind: Atom.to_string(kind)}
    |> maybe_put(:codec, Map.get(stream, :codec))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        @table
    end
  end
end
