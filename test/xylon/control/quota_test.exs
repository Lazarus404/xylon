defmodule Xylon.Control.QuotaTest do
  use ExUnit.Case, async: false

  alias Xylon.Control.Quota

  setup do
    start_supervised!(Quota)

    Application.put_env(:xylon, :control,
      enabled: true,
      auth: :lab,
      quotas: %{inject_per_minute: 2, join_per_minute: 2, max_participants: 2}
    )

    on_exit(fn -> Application.delete_env(:xylon, :control) end)
    Quota.reset()
    :ok
  end

  test "inject over limit returns rate_limited" do
    assert :ok = Quota.check_inject("t", "s")
    assert :ok = Quota.check_inject("t", "s")
    assert {:error, :rate_limited} = Quota.check_inject("t", "s")
  end

  test "max participants" do
    assert :ok = Quota.check_max_participants("t", "s", 1)
    assert {:error, :rate_limited} = Quota.check_max_participants("t", "s", 2)
  end

  test "gate_join skips when under limit and emits path on over limit" do
    assert :ok = Quota.gate_join("t", "s")
    assert :ok = Quota.gate_join("t", "s")
    assert {:error, :rate_limited} = Quota.gate_join("t", "s")
  end
end
