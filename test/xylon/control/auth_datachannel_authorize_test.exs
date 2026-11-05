defmodule Xylon.Control.AuthDatachannelAuthorizeTest do
  use ExUnit.Case, async: true

  alias Xylon.Control.Auth

  test "empty caps allow send" do
    fun = Auth.datachannel_authorize([])
    assert fun.(%{dir: :send, label: "chat"}) == true
  end

  test "list requires send or send:label" do
    fun = Auth.datachannel_authorize(["send:chat"])

    assert fun.(%{dir: :send, label: "chat", capabilities: ["send:chat"]}) == true
    assert fun.(%{dir: :send, label: "rpc", capabilities: ["send:chat"]}) == false
    assert fun.(%{dir: :send, label: "rpc", capabilities: ["send"]}) == true
  end

  test "uses meta capabilities over create-time caps" do
    fun = Auth.datachannel_authorize(["send:chat"])

    assert fun.(%{dir: :send, label: "chat", capabilities: []}) == true

    assert fun.(%{dir: :send, label: "chat", capabilities: ["send:rpc"]}) == false
  end

  test "map send true allows" do
    fun = Auth.datachannel_authorize(%{})

    assert fun.(%{dir: :publish, label: "chat", capabilities: %{"send" => true}}) == true
    assert fun.(%{dir: :publish, label: "chat", capabilities: %{"send" => false}}) == false
  end

  test "map send:label true allows per label" do
    fun = Auth.datachannel_authorize(%{})

    assert fun.(%{dir: :send, label: "chat", capabilities: %{"send:chat" => true}}) == true
    assert fun.(%{dir: :send, label: "rpc", capabilities: %{"send:chat" => true}}) == false
    assert fun.(%{dir: :send, label: "rpc", capabilities: %{"send:rpc" => true}}) == true
  end

  test "datachannel_authorize is arity 1" do
    fun = Auth.datachannel_authorize([])
    assert is_function(fun, 1)
    refute is_function(fun, 2)
  end
end
