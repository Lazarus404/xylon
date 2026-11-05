defmodule Xylon.Control.Secrets.ConfigTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Secrets
  alias Xylon.Control.Secrets.Record

  setup do
    prev = Application.get_env(:xylon, :control, [])

    on_exit(fn ->
      Application.put_env(:xylon, :control, prev)
    end)

    :ok
  end

  test "get returns global hmac_secret for any tenant" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: "lab-secret"
    )

    assert {:ok, %Record{current: "lab-secret"}} = Secrets.get("acme")
    assert {:ok, %Record{current: "lab-secret"}} = Secrets.get("other")
  end

  test "hmac_config_tenant_id gates tenants" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: "lab-secret",
      hmac_config_tenant_id: "acme"
    )

    assert {:ok, _} = Secrets.get("acme")
    assert {:error, :not_found} = Secrets.get("broke-co")
  end

  test "missing secret is not_found" do
    Application.put_env(:xylon, :control, enabled: true, auth: :hmac, hmac_secret: nil)
    assert {:error, :not_found} = Secrets.get("acme")
  end
end
