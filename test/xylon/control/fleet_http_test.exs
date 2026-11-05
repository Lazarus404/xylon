defmodule Xylon.Control.FleetHttpTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Xylon.Cluster.Accepting
  alias Xylon.Control.Context
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Membership

  @secret "fleet-http-secret"

  setup do
    Xylon.Catalogue.reset!()
    Accepting.reset!()
    assert :ok = Xylon.attach(Xylon.Backend.Echo)
    start_supervised!(Membership)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: @secret
    )

    on_exit(fn ->
      Accepting.reset!()
      Application.delete_env(:xylon, :control)
    end)

    :ok
  end

  defp token(caps \\ ["fleet"]) do
    HMAC.mint(
      %Context{
        tenant_id: "t1",
        session_id: "any",
        participant_id: "actor",
        capabilities: caps
      },
      @secret
    )
  end

  defp get_json(path, tok) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{tok}")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  defp post_json(path, tok, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("authorization", "Bearer #{tok}")
    |> put_req_header("content-type", "application/json")
    |> Xylon.Signaling.HTTP.call(Xylon.Signaling.HTTP.init([]))
  end

  test "fleet nodes and summary reflect live Membership counts" do
    sid = "fleet-http-#{System.unique_integer([:positive])}"
    assert {:ok, session} = Xylon.Session.create("t1", sid, :echo)
    :ok = Membership.join("t1", sid, "a", %{})
    :ok = Membership.join("t1", sid, "b", %{})

    conn = get_json("/v1/tenants/t1/fleet/nodes", token())
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["nodes"])
    self_row = Enum.find(body["nodes"], &(&1["node"] == Atom.to_string(Node.self())))
    assert self_row
    assert self_row["session_count"] >= 1
    assert self_row["participant_count"] >= 2
    assert self_row["reachable"] == true
    assert self_row["accepting"] == true
    refute Map.has_key?(self_row, "artifacts")

    conn = get_json("/v1/tenants/t1/fleet/summary", token())
    assert conn.status == 200
    summary = Jason.decode!(conn.resp_body)["summary"]
    assert summary["node_count"] >= 1
    assert summary["participant_count"] >= 2
    assert is_list(summary["regions"])
    refute Map.has_key?(summary, "media")

    GenServer.stop(session)
  end

  test "fleet capability required when caps are non-empty" do
    deny = token(["sessions"])
    conn = get_json("/v1/tenants/t1/fleet/nodes", deny)
    assert conn.status == 403

    lab = token([])
    conn = get_json("/v1/tenants/t1/fleet/summary", lab)
    assert conn.status == 200
    assert %{"summary" => _} = Jason.decode!(conn.resp_body)
  end

  test "POST fleet/accepting drains local node" do
    node = Atom.to_string(Node.self())
    conn = post_json("/v1/tenants/t1/fleet/accepting", token(), %{"node" => node, "accepting" => false})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"node" => node, "accepting" => false}
    assert Accepting.accepting?() == false

    conn = get_json("/v1/tenants/t1/fleet/nodes", token())
    self_row = Enum.find(Jason.decode!(conn.resp_body)["nodes"], &(&1["node"] == node))
    assert self_row["accepting"] == false
  end

  test "POST fleet/accepting unknown node is 404" do
    conn =
      post_json("/v1/tenants/t1/fleet/accepting", token(), %{
        "node" => "missing@host",
        "accepting" => false
      })

    assert conn.status == 404
  end
end
