defmodule Xylon.Control.Secrets.Record do
  @moduledoc """
  Tenant shared-secret material for HMAC verify (current + optional previous).

  ## What problem this solves

  Key rotation requires verifying tokens signed with either the current or
  previous secret until `previous_expires_at`. `Record` is the normalized shape
  returned by all `Secrets` adapters.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.
  """

  @enforce_keys [:current]
  defstruct current: nil,
            previous: nil,
            previous_expires_at: nil,
            disabled?: false,
            flags: %{}

  @typedoc """
  Tenant HMAC secret record (current + optional previous for rotation).

  ## Fields

  * `:current` - active shared secret binary (required)
  * `:previous` - prior secret still accepted until expiry, or `nil`
  * `:previous_expires_at` - unix seconds when `:previous` stops verifying, or `nil`
  * `:disabled?` - when true, adapters treat the tenant as missing
  * `:flags` - opaque metadata map for host policy
  """
  @type t :: %__MODULE__{
          current: binary(),
          previous: binary() | nil,
          previous_expires_at: integer() | nil,
          disabled?: boolean(),
          flags: map()
        }

  @doc "Builds a record from a map (string or atom keys)."
  @spec from_map(map()) :: {:ok, t()} | {:error, :not_found}
  def from_map(map) when is_map(map) do
    current = Map.get(map, :current) || Map.get(map, "current")

    if is_binary(current) and current != "" do
      previous = Map.get(map, :previous) || Map.get(map, "previous")
      previous = if previous == "", do: nil, else: previous

      expires =
        coerce_unix(
          Map.get(map, :previous_expires_at) || Map.get(map, "previous_expires_at")
        )

      disabled? =
        case Map.get(map, :disabled?) || Map.get(map, "disabled?") || Map.get(map, "disabled") do
          true -> true
          _ -> false
        end

      flags =
        case Map.get(map, :flags) || Map.get(map, "flags") || %{} do
          f when is_map(f) -> f
          _ -> %{}
        end

      if disabled? do
        {:error, :not_found}
      else
        {:ok,
         %__MODULE__{
           current: current,
           previous: previous,
           previous_expires_at: expires,
           disabled?: false,
           flags: flags
         }}
      end
    else
      {:error, :not_found}
    end
  end

  defp coerce_unix(nil), do: nil
  defp coerce_unix(n) when is_integer(n), do: n
  defp coerce_unix(n) when is_float(n), do: trunc(n)

  defp coerce_unix(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp coerce_unix(_), do: nil
end
