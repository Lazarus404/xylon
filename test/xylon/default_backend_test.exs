defmodule Xylon.DefaultBackendTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:xylon, :default_backend)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:xylon, :default_backend)
      else
        Application.put_env(:xylon, :default_backend, previous)
      end
    end)

    :ok
  end

  test "default_backend/0 reads application env" do
    Application.put_env(:xylon, :default_backend, :datachannel)
    assert Xylon.default_backend() == :datachannel

    Application.delete_env(:xylon, :default_backend)
    assert Xylon.default_backend() == :echo
  end
end
