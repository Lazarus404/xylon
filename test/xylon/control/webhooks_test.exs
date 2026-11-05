defmodule Xylon.Control.WebhooksTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Webhooks
  alias Xylon.Control.Webhooks.Delivery

  defmodule CapturePlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pid = Application.get_env(:xylon, :webhook_test_pid)

      if is_pid(pid) do
        send(pid, {:webhook, Plug.Conn.get_req_header(conn, "x-xylon-signature"), body})
      end

      send_resp(conn, 200, "ok")
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  defmodule AlwaysFailPlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    post "/" do
      send_resp(conn, 500, "no")
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  test "sign produces verifiable sha256 hmac hex" do
    body = ~s({"type":"participant.joined"})
    secret = "whsec"
    sig = Delivery.sign(body, secret)
    assert sig =~ ~r/^sha256=[0-9a-f]+$/
    assert Delivery.valid_signature?(body, secret, sig)
    refute Delivery.valid_signature?(body, "other", sig)
  end

  test "deliver posts signed body to webhook_url" do
    Application.put_env(:xylon, :webhook_test_pid, self())
    port = 19_000 + rem(System.unique_integer([:positive]), 1000)

    {:ok, pid} =
      Bandit.start_link(plug: CapturePlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)
      Application.delete_env(:xylon, :webhook_test_pid)
      Application.delete_env(:xylon, :control)
    end)

    url = "http://127.0.0.1:#{port}/"

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: url,
      webhook_secret: "s3cret"
    )

    payload = %{"type" => "participant.joined", "tenant_id" => "t1"}
    assert :ok = Delivery.deliver("participant.joined", payload)

    assert_receive {:webhook, [sig], body}, 2_000
    assert Delivery.valid_signature?(body, "s3cret", sig)
    assert Jason.decode!(body)["type"] == "participant.joined"
  end

  test "deliver retries three times then fails without sleeping after last try" do
    port = 19_000 + rem(System.unique_integer([:positive]), 1000)

    {:ok, pid} =
      Bandit.start_link(plug: AlwaysFailPlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)
      Application.delete_env(:xylon, :control)
    end)

    Application.put_env(:xylon, :control,
      enabled: true,
      webhook_url: "http://127.0.0.1:#{port}/",
      webhook_secret: "s3cret"
    )

    t0 = System.monotonic_time(:millisecond)
    assert {:error, :delivery_failed} = Delivery.deliver("quota.exceeded", %{"tenant_id" => "t"})
    elapsed = System.monotonic_time(:millisecond) - t0

    # Backoff between tries is 100 + 400 = 500ms; must not also sleep the final 1600ms.
    assert elapsed < 1_500
    assert elapsed >= 400
  end

  test "emit is no-op when webhook_url unset" do
    Application.put_env(:xylon, :control, enabled: true)
    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    assert :ok = Webhooks.emit("participant.joined", %{"tenant_id" => "t"})
  end
end
