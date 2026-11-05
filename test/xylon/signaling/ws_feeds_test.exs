defmodule Xylon.Signaling.WSFeedsTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Context, Feeds, Groups, Membership, Moderation, Presence, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Signaling.WSHandler

  @secret "ws-feeds-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Groups)
    start_supervised!(Presence)
    start_supervised!(Feeds)
    start_supervised!(Quota)
    start_supervised!(Moderation)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  defp push(state, map) do
    WSHandler.handle_in({Jason.encode!(map), [opcode: :text]}, state)
  end

  defp decode_frames({:push, {:text, bin}, state}) when is_binary(bin) do
    {[Jason.decode!(bin)], state}
  end

  defp decode_frames({:push, frames, state}) when is_list(frames) do
    decoded =
      Enum.map(frames, fn
        {:text, bin} -> Jason.decode!(bin)
        [text: bin] -> Jason.decode!(bin)
      end)

    {decoded, state}
  end

  test "join pushes presence.snapshot and feeds.snapshot when Presence is up" do
    sid = "ws-feeds-#{System.unique_integer([:positive])}"

    assert :ok =
             Feeds.put("t1", sid, "alice", %{
               streams: [%{mid: "0", kind: :audio, codec: "opus"}]
             })

    :ok = Membership.join("t1", sid, "alice", %{})
    :ok = Groups.create("t1", sid, "team")
    :ok = Groups.add_member("t1", sid, "team", "alice")

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {frames, _state} =
      decode_frames(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "bob"
        })
      )

    assert Enum.any?(frames, &(&1["type"] == "joined"))
    assert Enum.any?(frames, &(&1["type"] == "presence.snapshot"))
    assert Enum.any?(frames, &(&1["type"] == "groups.snapshot"))

    groups = Enum.find(frames, &(&1["type"] == "groups.snapshot"))
    assert groups["groups"]["team"] == ["alice"]

    feeds = Enum.find(frames, &(&1["type"] == "feeds.snapshot"))
    assert feeds

    assert [
             %{
               "participant_id" => "alice",
               "streams" => [%{"mid" => "0", "kind" => "audio", "codec" => "opus"}]
             }
           ] = feeds["publishers"]
  end

  test "feeds.diff published is pushed to subscribed WS" do
    sid = "ws-feeds-diff-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "bob", capabilities: []},
        @secret
      )

    {:ok, state} = WSHandler.init([])

    {_frames, state} =
      decode_frames(
        push(state, %{
          type: "join",
          token: token,
          library: "echo",
          participant_id: "bob"
        })
      )

    assert :ok =
             Feeds.put("t1", sid, "alice", %{
               streams: [%{mid: "1", kind: :video, codec: "VP8"}]
             })

    assert {:push, {:text, bin}, _} =
             WSHandler.handle_info(
               {:xylon_control_presence,
                %{
                  type: :feeds_diff,
                  action: :published,
                  participant_id: "alice",
                  streams: [%{mid: "1", kind: "video", codec: "VP8"}]
                }},
               state
             )

    assert %{
             "type" => "feeds.diff",
             "action" => "published",
             "participant_id" => "alice",
             "streams" => [%{"mid" => "1", "kind" => "video", "codec" => "VP8"}]
           } = Jason.decode!(bin)
  end
end
