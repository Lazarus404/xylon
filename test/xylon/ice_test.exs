defmodule Xylon.IceTest do
  use ExUnit.Case, async: false

  alias Xylon.Ice

  setup do
    prev = Application.get_env(:xylon, :ice)

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:xylon, :ice)
      else
        Application.put_env(:xylon, :ice, prev)
      end
    end)

    Application.delete_env(:xylon, :ice)
    :ok
  end

  test "listener_opts! requires advertised_ip or advertised_ips" do
    assert_raise ArgumentError, ~r/config :xylon, :ice/, fn ->
      Ice.listener_opts!()
    end
  end

  test "listener_opts! returns advertised_ip" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
    assert [advertised_ip: {127, 0, 0, 1}] = Ice.listener_opts!()
  end

  test "listener_opts! returns advertised_ips" do
    ips = [{192, 0, 2, 1}, {198, 51, 100, 1}]
    Application.put_env(:xylon, :ice, advertised_ips: ips)
    assert [advertised_ips: ^ips] = Ice.listener_opts!()
  end

  test "put_ips_env! sets advertised_ips from CSV" do
    assert :ok = Ice.put_ips_env!("127.0.0.1, 10.0.0.5")
    assert [advertised_ips: [{127, 0, 0, 1}, {10, 0, 0, 5}]] = Ice.listener_opts!()
  end

  test "ensure_configured! loads XYLON_ADVERTISED_IPS over single IP" do
    System.put_env("XYLON_ADVERTISED_IPS", "127.0.0.1,192.0.2.9")

    on_exit(fn ->
      System.delete_env("XYLON_ADVERTISED_IPS")
    end)

    assert :ok = Ice.ensure_configured!()
    assert [advertised_ips: [{127, 0, 0, 1}, {192, 0, 2, 9}]] = Ice.listener_opts!()
  end

  test "put_env! sets advertised_ip from string" do
    assert :ok = Ice.put_env!("10.0.0.5")
    assert [advertised_ip: {10, 0, 0, 5}] = Ice.listener_opts!()
  end

  test "put_env! rejects missing and invalid" do
    assert_raise ArgumentError, ~r/XYLON_ADVERTISED_IP is required/, fn ->
      Ice.put_env!(nil)
    end

    assert_raise ArgumentError, ~r/must be an IP address/, fn ->
      Ice.put_env!("not-an-ip")
    end
  end

  test "ensure_configured! is a no-op when already set" do
    Application.put_env(:xylon, :ice, advertised_ip: {203, 0, 113, 1})
    assert :ok = Ice.ensure_configured!()
    assert [advertised_ip: {203, 0, 113, 1}] = Ice.listener_opts!()
  end

  test "summary formats configured address" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
    assert Ice.summary() == "127.0.0.1"
  end

  test "mode defaults to :lite and full?/0 is false" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
    assert Ice.mode() == :lite
    refute Ice.full?()
  end

  test "mode :full sets full?/0" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1}, mode: :full)
    assert Ice.mode() == :full
    assert Ice.full?()
  end

  test "stun_listener_opts/0 returns configured stun and turn servers" do
    Application.put_env(:xylon, :ice,
      advertised_ip: {127, 0, 0, 1},
      stun_servers: ["stun.l.google.com:19302"],
      turn_servers: ["turn:example.com:3478"]
    )

    opts = Ice.stun_listener_opts()
    assert opts[:stun_servers] == ["stun:stun.l.google.com:19302"]
    assert opts[:turn_servers] == ["turn:example.com:3478"]
  end

  test "stun_listener_opts/0 is empty when unset" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
    assert Ice.stun_listener_opts() == []
  end

  test "ensure_configured! loads XYLON_ICE_MODE and XYLON_STUN_SERVERS" do
    Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})

    System.put_env("XYLON_ICE_MODE", "full")
    System.put_env("XYLON_STUN_SERVERS", "stun.example:3478,stun2.example:3478")

    on_exit(fn ->
      System.delete_env("XYLON_ICE_MODE")
      System.delete_env("XYLON_STUN_SERVERS")
    end)

    assert :ok = Ice.ensure_configured!()
    assert Ice.mode() == :full

    assert Ice.stun_listener_opts()[:stun_servers] == [
             "stun:stun.example:3478",
             "stun:stun2.example:3478"
           ]
  end

  test "stun_listener_opts normalizes host:port to stun: URI" do
    Application.put_env(:xylon, :ice,
      advertised_ip: {127, 0, 0, 1},
      stun_servers: ["stun.l.google.com:19302", "stun:keep.example:3478"]
    )

    assert Ice.stun_listener_opts()[:stun_servers] == [
             "stun:stun.l.google.com:19302",
             "stun:keep.example:3478"
           ]
  end
end
