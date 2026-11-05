defmodule Xylon.Signaling.WSSubscribeTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Context, Membership, Moderation, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Signaling.WSHandler

  @secret "ws-sub-hmac-secret"

  defmodule SubBackend do
    @behaviour Xylon.Backend

    def id, do: :ws_sub

    def init(_session, _opts), do: {:ok, %{subs: [], layers: []}}
    def participant_joined(_p, state), do: {:ok, state}
    def participant_left(_p, state), do: {:ok, state}
    def handle_rtp(_p, _rtp, state), do: {:ok, state}
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}
    def terminate(_r, _s), do: :ok

    def subscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: [{sub, pub, mid} | state.subs]}}
    end

    def unsubscribe(sub, pub, mid, _opts, state) do
      {:ok, %{state | subs: List.delete(state.subs, {sub, pub, mid})}}
    end

    def set_substream(sub, pub, mid, opts, state) do
      {:ok, %{state | layers: [{sub, pub, mid, opts} | state.layers]}}
    end

    def switch(sub, to_pub, mid, _opts, state) do
      case Enum.find(state.subs, fn {s, _p, m} -> s == sub and m == mid end) do
        {^sub, from, ^mid} ->
          subs =
            state.subs
            |> List.delete({sub, from, mid})
            |> then(&[{sub, to_pub, mid} | &1])

          {:ok, %{state | subs: subs}}

        nil ->
          {:error, :no_route}
      end
    end
  end

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(Moderation)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(SubBackend)

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  defp push(state, map) do
    WSHandler.handle_in({Jason.encode!(map), [opcode: :text]}, state)
  end

  defp text_payload({:text, bin}) when is_binary(bin), do: bin
  defp text_payload([{:text, bin} | _]) when is_binary(bin), do: bin
  defp text_payload([text: bin]) when is_binary(bin), do: bin

  defp assert_push_text({:push, pushed, state}) do
    {text_payload(pushed), state}
  end

  test "subscribe and unsubscribe frames" do
    sid = "ws-sub-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "b",
          capabilities: []
        },
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {_joined, state} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "ws_sub",
          participant_id: "b"
        })
      )

    {body, state} =
      assert_push_text(
        push(state, %{type: "subscribe", publisher_id: "a", mid: "1"})
      )

    assert %{"type" => "subscribed"} = Jason.decode!(body)

    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", "a", "1"}] = :sys.get_state(session).backend_state.subs

    {body, _} =
      assert_push_text(
        push(state, %{type: "unsubscribe", publisher_id: "a", mid: "1"})
      )

    assert %{"type" => "unsubscribed"} = Jason.decode!(body)
    assert [] = :sys.get_state(session).backend_state.subs
  end

  test "switch frame rebinds publisher" do
    sid = "ws-sw-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "b",
          capabilities: []
        },
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {_joined, state} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "ws_sub",
          participant_id: "b"
        })
      )

    {_body, state} =
      assert_push_text(
        push(state, %{type: "subscribe", publisher_id: "a", mid: "0"})
      )

    {body, _} =
      assert_push_text(
        push(state, %{type: "switch", publisher_id: "c", mid: "0"})
      )

    assert %{"type" => "switched"} = Jason.decode!(body)
    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", "c", "0"}] = :sys.get_state(session).backend_state.subs
  end

  test "set_substream frame passes substream and rid" do
    sid = "ws-layer-#{System.unique_integer([:positive])}"

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: sid,
          participant_id: "b",
          capabilities: []
        },
        @secret
      )

    {:ok, state} = WSHandler.init(conn_id: "c1", query: %{})

    {_joined, state} =
      assert_push_text(
        push(state, %{
          type: "join",
          token: token,
          library: "ws_sub",
          participant_id: "b"
        })
      )

    {body, _} =
      assert_push_text(
        push(state, %{
          type: "set_substream",
          publisher_id: "a",
          mid: "1",
          substream: 1,
          rid: "h"
        })
      )

    assert %{"type" => "substream_set"} = Jason.decode!(body)
    session = Xylon.Session.whereis("t1", sid)
    assert [{"b", "a", "1", opts}] = :sys.get_state(session).backend_state.layers
    assert Keyword.get(opts, :substream) == 1
    assert Keyword.get(opts, :rid) == "h"
  end
end
