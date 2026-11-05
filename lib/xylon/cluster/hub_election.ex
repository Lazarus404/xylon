defmodule Xylon.Cluster.HubElection do
  @moduledoc """
  Pure deterministic regional hub election.

  ## What problem this solves

  Every region needs exactly one hub for inter-region trunks. Election must be
  reproducible across nodes without a central coordinator: highest configured
  priority wins; equal priority breaks ties with the lowest node name string.

  ## RFCs

  None.
  """

  @doc """
  Elects the hub node from `{node, priority}` candidates.

  Highest priority wins. On a tie, the lowest `Atom.to_string(node)` wins.
  Raises `ArgumentError` when `candidates` is empty.
  """
  @spec elect([{node(), integer()}]) :: node()
  def elect([]), do: raise(ArgumentError, "hub election requires at least one candidate")

  def elect(candidates) when is_list(candidates) do
    candidates
    |> Enum.min_by(fn {node, priority} -> {-priority, Atom.to_string(node)} end)
    |> elem(0)
  end
end
