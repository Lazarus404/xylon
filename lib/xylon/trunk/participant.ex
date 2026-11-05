defmodule Xylon.Trunk.Participant do
  @moduledoc """
  Helpers to build trunk-role participants for multi-home cascade.

  ## What problem this solves

  Cascade edges present the far media pipe as a normal session member so
  conference and datachannel Plans can forward to it without a second Backend.
  This module builds `%Xylon.Participant{role: :trunk}` around an
  `XGW.Trunk.Pipe` pid.

  ## RFCs

  None directly; media bytes use the trunk pipe (RFC 3711 SRTP on the wire).
  """

  alias Xylon.Participant

  @doc """
  Builds a trunk participant pointing at `pipe` as `peer_ref`.
  """
  @spec build(term(), pid(), keyword()) :: Participant.t()
  def build(id, pipe, opts \\ []) when is_pid(pipe) do
    %Participant{
      id: id,
      peer_ref: pipe,
      listener: nil,
      role: :trunk,
      meta: Keyword.get(opts, :meta, %{trunk: true})
    }
  end
end
