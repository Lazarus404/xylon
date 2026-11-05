defmodule Xylon.Control.Grpc.PresenceHistoryTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Context, History, Membership, Presence}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Grpc.{HistoryServer, PresenceServer}
  alias Xylon.Control.V1.{GetHistoryRequest, GetHistoryResponse, GetPresenceRequest, GetPresenceResponse}

  defmodule FakeAdapter do
    @moduledoc false
    def get_headers(payload) when is_map(payload), do: payload
    def get_headers(_), do: %{}
  end

  @secret "grpc-read-test-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Presence)
    start_supervised!(History)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    History.reset()

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  test "GetPresence happy path with HMAC bearer" do
    session_id = "pres-#{System.unique_integer([:positive])}"
    :ok = Membership.join("t1", session_id, "a", %{role: :member, joined_at: 42})

    token = mint(session_id)

    resp =
      PresenceServer.get(
        %GetPresenceRequest{tenant_id: "t1", session_id: session_id},
        stream(token)
      )

    assert %GetPresenceResponse{participants: %{"a" => p}} = resp
    assert p.role == "member"
    assert p.joined_at == 42
  end

  test "GetPresence missing bearer is unauthenticated" do
    err =
      assert_raise GRPC.RPCError, fn ->
        PresenceServer.get(
          %GetPresenceRequest{tenant_id: "t1", session_id: "s1"},
          stream(nil)
        )
      end

    assert err.status == GRPC.Status.unauthenticated()
  end

  test "GetPresence wrong session bind is permission_denied" do
    session_id = "pres-forbid-#{System.unique_integer([:positive])}"
    token = mint(session_id)

    err =
      assert_raise GRPC.RPCError, fn ->
        PresenceServer.get(
          %GetPresenceRequest{tenant_id: "t1", session_id: "other"},
          stream(token)
        )
      end

    assert err.status == GRPC.Status.permission_denied()
  end

  test "GetHistory happy path and default label chat" do
    session_id = "hist-#{System.unique_integer([:positive])}"
    :ok = History.append("t1", session_id, "chat", "a", "hello")

    token = mint(session_id)

    resp =
      HistoryServer.get(
        %GetHistoryRequest{tenant_id: "t1", session_id: session_id, label: ""},
        stream(token)
      )

    assert %GetHistoryResponse{messages: [msg]} = resp
    assert msg.from == "a"
    assert msg.label == "chat"
    assert msg.payload == "hello"
    assert msg.ts > 0
  end

  test "GetHistory respects explicit label" do
    session_id = "hist-lbl-#{System.unique_integer([:positive])}"
    :ok = History.append("t1", session_id, "notes", "b", "n1")

    token = mint(session_id)

    resp =
      HistoryServer.get(
        %GetHistoryRequest{tenant_id: "t1", session_id: session_id, label: "notes"},
        stream(token)
      )

    assert %GetHistoryResponse{messages: [msg]} = resp
    assert msg.label == "notes"
    assert msg.payload == "n1"
  end

  test "lab auth mode is failed_precondition" do
    Application.put_env(:xylon, :control, enabled: true, auth: :lab)

    err =
      assert_raise GRPC.RPCError, fn ->
        PresenceServer.get(
          %GetPresenceRequest{tenant_id: "t1", session_id: "s1"},
          stream("any")
        )
      end

    assert err.status == GRPC.Status.failed_precondition()
  end

  defp mint(session_id) do
    HMAC.mint(
      %Context{
        tenant_id: "t1",
        session_id: session_id,
        participant_id: "host",
        capabilities: []
      },
      @secret
    )
  end

  defp stream(nil), do: %GRPC.Server.Stream{adapter: FakeAdapter, payload: %{}}

  defp stream(token) when is_binary(token) do
    %GRPC.Server.Stream{
      adapter: FakeAdapter,
      payload: %{"authorization" => "Bearer #{token}"}
    }
  end
end
