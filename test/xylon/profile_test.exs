defmodule Xylon.ProfileTest do
  use ExUnit.Case, async: false

  test "enabled? follows XYLON_RTP_PROFILE" do
    prev = System.get_env("XYLON_RTP_PROFILE")

    on_exit(fn ->
      if prev do
        System.put_env("XYLON_RTP_PROFILE", prev)
      else
        System.delete_env("XYLON_RTP_PROFILE")
      end
    end)

    System.put_env("XYLON_RTP_PROFILE", "1")
    assert Xylon.Profile.enabled?()

    System.put_env("XYLON_RTP_PROFILE", "0")
    refute Xylon.Profile.enabled?()
  end

  test "children/0 is empty when disabled" do
    prev = System.get_env("XYLON_RTP_PROFILE")

    on_exit(fn ->
      if prev do
        System.put_env("XYLON_RTP_PROFILE", prev)
      else
        System.delete_env("XYLON_RTP_PROFILE")
      end
    end)

    System.delete_env("XYLON_RTP_PROFILE")
    assert Xylon.Profile.children() == []
  end
end
