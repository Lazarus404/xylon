defmodule Xylon.Control.Secrets.LocalTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Secrets.Local
  alias Xylon.Control.Secrets.Record

  defmodule RevealPlug do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    get "/v1/tenants/:tid" do
      case tid do
        "acme" ->
          send_resp(
            conn,
            200,
            Jason.encode!(%{
              "current" => "sec",
              "previous" => nil,
              "previous_expires_at" => nil,
              "disabled?" => false,
              "flags" => %{}
            })
          )

        "foo bar" ->
          send_resp(conn, 200, Jason.encode!(%{"current" => "spaced", "disabled?" => false}))

        "acme/extra" ->
          send_resp(conn, 200, Jason.encode!(%{"current" => "slashy", "disabled?" => false}))

        "missing" ->
          send_resp(conn, 404, ~s({"error":"not_found"}))

        "disabled" ->
          send_resp(
            conn,
            200,
            Jason.encode!(%{"current" => "sec", "disabled?" => true})
          )

        _ ->
          send_resp(conn, 404, "no")
      end
    end

    match _ do
      send_resp(conn, 404, "no")
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    port = 19_100 + rem(System.unique_integer([:positive]), 800)

    {:ok, pid} =
      Bandit.start_link(plug: RevealPlug, scheme: :http, port: port, ip: {127, 0, 0, 1})

    on_exit(fn -> Process.exit(pid, :normal) end)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "get parses reveal JSON from stub store", %{url: url} do
    assert {:ok, %Record{current: "sec"}} = Local.get("acme", url: url)
  end

  test "get encodes path separators in tenant id", %{url: url} do
    assert {:ok, %Record{current: "slashy"}} = Local.get("acme/extra", url: url)
  end

  test "get encodes reserved characters in tenant path", %{url: url} do
    assert {:ok, %Record{current: "spaced"}} = Local.get("foo bar", url: url)
  end

  test "get returns not_found on 404", %{url: url} do
    assert {:error, :not_found} = Local.get("missing", url: url)
  end

  test "get returns not_found when disabled", %{url: url} do
    assert {:error, :not_found} = Local.get("disabled", url: url)
  end
end
