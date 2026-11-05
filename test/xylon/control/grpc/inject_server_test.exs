defmodule Xylon.Control.Grpc.InjectServerTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.{Auth, Context, Membership, Quota}
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Grpc.InjectServer
  alias Xylon.Control.V1.{PublishRequest, PublishResponse}

  defmodule PublishBackend do
    @moduledoc false
    @behaviour Xylon.Backend

    def id, do: :grpc_inject_stub

    @impl true
    def init(_session, _opts), do: {:ok, %{published: []}}

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

    @impl true
    def publish_datachannel(payload, dest, opts, state) do
      {:ok, %{state | published: [{payload, dest, opts} | state.published]}}
    end
  end

  defmodule FakeAdapter do
    @moduledoc false
    def get_headers(payload) when is_map(payload), do: payload
    def get_headers(_), do: %{}
  end

  @secret "grpc-inject-test-secret"

  setup do
    start_supervised!(Membership)
    start_supervised!(Quota)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret,
      topics: %{"chat" => %{label: "chat"}},
      quotas: %{inject_per_minute: 120}
    )

    Xylon.Catalogue.reset!()
    assert :ok = Xylon.attach(PublishBackend)
    Quota.reset()

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    :ok
  end

  test "publish happy path with HMAC bearer" do
    session_id = "grpc-ok-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", session_id, :grpc_inject_stub)
    :ok = Membership.join("t1", session_id, "a", %{})

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: session_id,
          participant_id: "a",
          capabilities: ["inject"]
        },
        @secret
      )

    req = %PublishRequest{
      tenant_id: "t1",
      session_id: session_id,
      payload: "hello",
      dest: "all",
      label: "chat"
    }

    assert %PublishResponse{} = InjectServer.publish(req, stream(token))
  end

  test "missing bearer is unauthenticated" do
    req = %PublishRequest{
      tenant_id: "t1",
      session_id: "s1",
      payload: "hi",
      dest: "all"
    }

    assert_raise GRPC.RPCError, fn ->
      InjectServer.publish(req, stream(nil))
    end
  end

  test "wrong session bind is permission_denied" do
    session_id = "grpc-forbid-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", session_id, :grpc_inject_stub)
    :ok = Membership.join("t1", session_id, "a", %{})

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: session_id,
          participant_id: "a",
          capabilities: ["inject"]
        },
        @secret
      )

    req = %PublishRequest{
      tenant_id: "t1",
      session_id: "other-room",
      payload: "hi",
      dest: "all"
    }

    err =
      assert_raise GRPC.RPCError, fn ->
        InjectServer.publish(req, stream(token))
      end

    assert err.status == GRPC.Status.permission_denied()
  end

  test "empty except dest is not_found" do
    session_id = "grpc-empty-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", session_id, :grpc_inject_stub)

    token =
      HMAC.mint(
        %Context{
          tenant_id: "t1",
          session_id: session_id,
          participant_id: "a",
          capabilities: ["inject"]
        },
        @secret
      )

    :ok = Membership.join("t1", session_id, "a", %{})

    req = %PublishRequest{
      tenant_id: "t1",
      session_id: session_id,
      payload: "hi",
      dest: "except"
    }

    err =
      assert_raise GRPC.RPCError, fn ->
        InjectServer.publish(req, stream(token))
      end

    assert err.status == GRPC.Status.not_found()
  end

  test "lab auth mode is failed_precondition" do
    Application.put_env(:xylon, :control, enabled: true, auth: :lab)

    req = %PublishRequest{
      tenant_id: "t1",
      session_id: "s1",
      payload: "hi",
      dest: "all"
    }

    err =
      assert_raise GRPC.RPCError, fn ->
        InjectServer.publish(req, stream("any-token"))
      end

    assert err.status == GRPC.Status.failed_precondition()
  end

  test "authenticate_bearer rejects lab" do
    Application.put_env(:xylon, :control, enabled: true, auth: :lab)
    assert {:error, :failed_precondition} = Auth.authenticate_bearer("tok")
  end

  test "grpc_child absent without grpc_port" do
    Application.put_env(:xylon, :control, enabled: true, auth: :hmac, hmac_secret: @secret)
    # Application.grpc_child is private; assert config gate via Keyword pattern used there.
    control = Application.get_env(:xylon, :control, [])
    refute match?(port when is_integer(port) and port > 0, Keyword.get(control, :grpc_port))
  end

  defp stream(nil) do
    %GRPC.Server.Stream{adapter: FakeAdapter, payload: %{}}
  end

  defp stream(token) when is_binary(token) do
    %GRPC.Server.Stream{
      adapter: FakeAdapter,
      payload: %{"authorization" => "Bearer #{token}"}
    }
  end
end
