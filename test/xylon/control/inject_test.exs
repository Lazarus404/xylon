defmodule Xylon.Control.InjectTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Control.{Auth, Context, Membership, Quota}
  alias Xylon.Control.Auth.HMAC

  defmodule PublishBackend do
    @moduledoc false
    @behaviour Xylon.Backend

    def id, do: :control_publish_stub

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

  @secret "inject-test-secret"

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

  test "inject without token is 401" do
    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/s1/data",
        Jason.encode!(%{payload: "hi", dest: "all"})
      )
      |> put_req_header("content-type", "application/json")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 401
  end

  test "empty dest is 404" do
    session_id = "inj-empty-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Xylon.Session.create("t1", session_id, :control_publish_stub)

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

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{session_id}/data",
        Jason.encode!(%{payload: "hi", dest: "except"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 404
    assert conn.resp_body =~ "empty dest"
  end

  test "happy path publish" do
    session_id = "inj-ok-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Xylon.Session.create("t1", session_id, :control_publish_stub)

    :ok = Membership.join("t1", session_id, "a", %{})
    :ok = Membership.join("t1", session_id, "b", %{})

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

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/#{session_id}/data",
        Jason.encode!(%{payload: "hello", dest: "all", label: "chat"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 200
    state = :sys.get_state(pid)
    assert [{"hello", :all, opts} | _] = state.backend_state.published
    assert opts[:label] == "chat"
  end

  test "room mismatch is 403" do
    token =
      HMAC.mint(
        %Context{tenant_id: "t1", session_id: "other", participant_id: "a", capabilities: []},
        @secret
      )

    conn =
      conn(
        :post,
        "/v1/tenants/t1/sessions/s1/data",
        Jason.encode!(%{payload: "hi", dest: "all"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))

    assert conn.status == 403
  end

  test "Auth.mint uses config secret" do
    ctx = %Context{tenant_id: "t1", session_id: "s", participant_id: "p", capabilities: []}
    assert {:ok, token} = Auth.mint(ctx)
    assert {:ok, ^ctx} = HMAC.verify(token, @secret)
  end
end
