defmodule Xylon.Control.Auth.VerifyHmacTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Auth
  alias Xylon.Control.Auth.HMAC
  alias Xylon.Control.Context
  alias Xylon.Control.Secrets.Record

  setup do
    prev = Application.get_env(:xylon, :control, [])

    on_exit(fn ->
      Application.put_env(:xylon, :control, prev)
    end)

    :ok
  end

  test "verify_hmac_token with Config adapter" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      hmac_secret: "s1"
    )

    ctx = %Context{tenant_id: "acme", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, "s1", ttl_sec: 60)
    assert {:ok, ^ctx} = Auth.verify_hmac_token(token)
  end

  test "verify_hmac_token accepts previous within grace" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      secrets: {__MODULE__.StubSecrets, grace: :active}
    )

    ctx = %Context{tenant_id: "acme", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, "old", ttl_sec: 60)
    assert {:ok, ^ctx} = Auth.verify_hmac_token(token)
  end

  test "verify_hmac_token rejects previous after grace" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      secrets: {__MODULE__.StubSecrets, grace: :expired}
    )

    ctx = %Context{tenant_id: "acme", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, "old", ttl_sec: 60)
    assert {:error, :unauthorized} = Auth.verify_hmac_token(token)
  end

  test "verify_hmac_token rejects missing tenant" do
    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :hmac,
      secrets: {__MODULE__.EmptySecrets, []}
    )

    ctx = %Context{tenant_id: "ghost", session_id: "r", participant_id: "a", capabilities: []}
    token = HMAC.mint(ctx, "s1", ttl_sec: 60)
    assert {:error, :unauthorized} = Auth.verify_hmac_token(token)
  end

  defmodule EmptySecrets do
    @behaviour Xylon.Control.Secrets
    def get(_tid, _opts), do: {:error, :not_found}
  end

  defmodule StubSecrets do
    @behaviour Xylon.Control.Secrets

    def get("acme", opts) do
      expires =
        case Keyword.get(opts, :grace, :active) do
          :expired -> System.system_time(:second) - 10
          _ -> System.system_time(:second) + 3600
        end

      {:ok,
       %Record{
         current: "new",
         previous: "old",
         previous_expires_at: expires,
         flags: %{}
       }}
    end

    def get(_, _), do: {:error, :not_found}
  end
end
