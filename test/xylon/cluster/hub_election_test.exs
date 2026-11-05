defmodule Xylon.Cluster.HubElectionTest do
  use ExUnit.Case, async: true

  alias Xylon.Cluster.HubElection

  test "highest priority wins" do
    assert HubElection.elect([{:a@host, 1}, {:b@host, 5}, {:c@host, 3}]) == :b@host
  end

  test "tie breaks to lowest node name string" do
    assert HubElection.elect([{:z@host, 1}, {:a@host, 1}, {:m@host, 1}]) == :a@host
  end

  test "single candidate" do
    assert HubElection.elect([{:solo@host, 0}]) == :solo@host
  end
end
