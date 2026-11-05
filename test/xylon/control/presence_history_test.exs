defmodule Xylon.Control.PresenceHistoryTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Context, History, Membership, Quota}
  alias Xylon.Control.Auth.HMAC

  defmodule TapProbe do
    @moduledoc false
    @behaviour Xylon.Backend

    def id, do: :datachannel

    @impl true
    def init(_session, opts), do: {:ok, %{tap: Keyword.get(opts, :tap)}}

    @impl true
    def participant_joined(_p, state), do: {:ok, state}

    @impl true
    def participant_left(_p, state), do: {:ok, state}

    @impl true
    def handle_rtp(_p, _rtp, state), do: {:ok, state}

    @impl true
    def handle_rtcp(_p, _rtcp, state), do: {:ok, state}

    @impl true
    def handle_datachannel(_p, _ref, _data, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  @secret "ph-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)
    start_supervised!(History)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      history_limit: 10,
      history_max_bytes: 64
    )

    History.reset()

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  test "presence GET lists Membership with joined_at" do
    sid = "pres-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", sid, "a", %{role: "host", joined_at: 1_700_000_000})

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    conn =
      conn(:get, "/v1/tenants/t1/sessions/#{sid}/presence")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    assert %{"participants" => %{"a" => %{"joined_at" => 1_700_000_000}}} = Jason.decode!(conn.resp_body)
  end

  test "history append via tap and GET" do
    sid = "hist-#{System.unique_integer([:positive])}"
    tap = History.tap_fun("t1", sid)
    tap.({:in, "a", "chat", "hello"})
    tap.({:publish, :all, "chat", "from-server"})

    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: sid, participant_id: "a", capabilities: []},
        @secret
      )

    conn =
      conn(:get, "/v1/tenants/t1/sessions/#{sid}/history?label=chat")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    assert %{"messages" => messages} = Jason.decode!(conn.resp_body)
    assert length(messages) == 2
    assert Enum.any?(messages, &(&1["payload"] == "hello" and &1["from"] == "a"))
  end

  test "history truncates payload bytes" do
    sid = "hist-trunc-#{System.unique_integer([:positive])}"
    big = String.duplicate("x", 200)
    :ok = History.append("t1", sid, "chat", "a", big)
    [row] = History.list("t1", sid, "chat")
    assert byte_size(row["payload"]) == 64
  end

  test "control-disabled start_session does not inject history tap" do
    Application.put_env(:xylon, :control, enabled: false)
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(TapProbe)
    assert {:ok, pid} = Xylon.Signaling.start_session("t1", "no-tap", :datachannel, [])
    state = :sys.get_state(pid)
    assert state.backend_state.tap == nil
  end

  test "control-enabled datachannel start_session merges history tap" do
    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(TapProbe)
    sid = "with-tap-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Xylon.Signaling.start_session("t1", sid, :datachannel, [])
    state = :sys.get_state(pid)
    assert is_function(state.backend_state.tap, 1)
  end
end
