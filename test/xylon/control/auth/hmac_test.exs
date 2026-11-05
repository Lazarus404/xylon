defmodule Xylon.Control.Auth.HMACTest do
  use ExUnit.Case, async: true

  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Context

  @secret "lab-secret-for-tests"

  test "mint and verify round-trip" do
    ctx = %Context{
      tenant_id: "t1",
      session_id: "room-1",
      participant_id: "a",
      capabilities: ["inject"]
    }

    token = HMAC.mint(ctx, @secret, ttl_sec: 60)
    assert {:ok, ^ctx} = HMAC.verify(token, @secret)
  end

  test "expired token is rejected" do
    ctx = %Context{tenant_id: "t1", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, @secret, ttl_sec: -10)
    assert {:error, :unauthorized} = HMAC.verify(token, @secret)
  end

  test "tampered token is rejected" do
    ctx = %Context{tenant_id: "t1", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, @secret)
    [p, m] = String.split(token, ".")
    bad = p <> "." <> String.replace_prefix(m, String.first(m), if(String.first(m) == "A", do: "B", else: "A"))
    assert {:error, :unauthorized} = HMAC.verify(bad, @secret)
  end

  test "wrong secret is rejected" do
    ctx = %Context{tenant_id: "t1", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, @secret)
    assert {:error, :unauthorized} = HMAC.verify(token, "other-secret")
  end

  test "peek_tenant_id reads clear claim" do
    ctx = %Context{tenant_id: "acme", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, @secret)
    assert {:ok, "acme"} = HMAC.peek_tenant_id(token)
  end

  test "peek_tenant_id rejects garbage" do
    assert {:error, :unauthorized} = HMAC.peek_tenant_id("not-a-token")
  end
end
