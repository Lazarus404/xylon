defmodule Xylon.Control.Secrets.RecordTest do
  use ExUnit.Case, async: true

  alias Xylon.Control.Secrets.Record

  test "from_map coerces previous_expires_at from string" do
    assert {:ok, %Record{previous_expires_at: 1_700_000_000}} =
             Record.from_map(%{
               "current" => "sec",
               "previous" => "old",
               "previous_expires_at" => "1700000000"
             })
  end

  test "from_map coerces previous_expires_at from float" do
    assert {:ok, %Record{previous_expires_at: 1_700_000_000}} =
             Record.from_map(%{
               "current" => "sec",
               "previous_expires_at" => 1_700_000_000.0
             })
  end
end
