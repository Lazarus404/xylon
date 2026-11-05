defmodule Xylon.Recording.MultiHomeHandler do
  @moduledoc false
  @behaviour Xylon.Recording.Handler

  alias Xylon.Recording.Ctx

  @impl true
  def on_start(%Ctx{}, _opts), do: {:ok, %{}}

  @impl true
  def on_stop(%Ctx{edge_node: edge}, _state) do
    edge_s = to_string(edge)

    {:ok,
     %{
       artifacts: [
         %{
           "kind" => "audio",
           "publisher_id" => "pub-#{edge_s}",
           "mid" => "0",
           "codec" => "opus",
           "path_or_key" => "/tmp/rec/#{edge_s}.mjr",
           "bytes" => 8,
           "via" => nil,
           "edge_node" => edge_s
         }
       ],
       counters: %{"packets" => 1, "bytes" => 8}
     }}
  end

  @impl true
  def on_publisher_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}

  @impl true
  def on_mix_rtp(%Ctx{}, state, _meta, _rtp), do: {:ok, state}
end
