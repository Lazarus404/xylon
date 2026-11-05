defmodule Xylon.Control.Dest do
  @moduledoc """
  Resolve inject destination filters to Backend publish targets.

  ## What problem this solves

  Server inject APIs accept flexible `dest` shapes (`all`, `except`, explicit
  ids, role/attr filters, named groups). Backends expect `:all` or a concrete
  participant id list. Dest normalizes against `Membership` / `Groups` and
  never returns `:except_sender` or unresolved filters.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.

  ## Examples

      iex> Xylon.Control.Dest.resolve("t", "s", :all)
      {:ok, :all}
      iex> Xylon.Control.Dest.resolve("t", "s", ["p1", "p2"])
      {:ok, ["p1", "p2"]}
      iex> Xylon.Control.Dest.resolve("t", "s", [])
      {:error, :empty_dest}
  """

  alias Xylon.Control.{Groups, Membership}

  @type dest_in :: :all | :except | binary() | [term()] | map()

  @doc """
  Resolves `dest` against Membership (and Groups for group filters) for
  `{tenant_id, session_id}`.

  `actor_id` is the inject sender (used for `except`).
  Empty resolved lists return `{:error, :empty_dest}`.
  Group filters: `%{"group" => id}` or `%{"groups" => [id, ...]}` (union),
  intersected with live Membership. Mixing group keys with `role`/`attr` is
  `:bad_dest`.
  """
  @spec resolve(term(), term(), dest_in(), term() | nil) ::
          {:ok, :all | [term()]} | {:error, :empty_dest | :bad_dest}
  def resolve(tenant_id, session_id, dest, actor_id \\ nil)

  def resolve(_tenant, _session, :all, _actor), do: {:ok, :all}
  def resolve(_tenant, _session, "all", _actor), do: {:ok, :all}

  def resolve(tenant_id, session_id, :except, actor_id),
    do: resolve_except(tenant_id, session_id, actor_id)

  def resolve(tenant_id, session_id, "except", actor_id),
    do: resolve_except(tenant_id, session_id, actor_id)

  def resolve(_tenant, _session, ids, _actor) when is_list(ids) do
    ids = Enum.uniq(ids)

    if ids == [] do
      {:error, :empty_dest}
    else
      {:ok, ids}
    end
  end

  def resolve(tenant_id, session_id, filter, _actor) when is_map(filter) do
    role = Map.get(filter, "role") || Map.get(filter, :role)
    attr = Map.get(filter, "attr") || Map.get(filter, :attr)
    group = Map.get(filter, "group") || Map.get(filter, :group)
    groups = Map.get(filter, "groups") || Map.get(filter, :groups)

    cond do
      group != nil or groups != nil ->
        if role != nil or attr != nil do
          {:error, :bad_dest}
        else
          resolve_groups(tenant_id, session_id, group, groups)
        end

      true ->
        resolve_role_attr(tenant_id, session_id, role, attr)
    end
  end

  def resolve(_, _, _, _), do: {:error, :bad_dest}

  defp resolve_groups(tenant_id, session_id, group, groups) do
    gids =
      cond do
        is_binary(group) and group != "" and groups == nil ->
          [group]

        is_list(groups) and group == nil ->
          groups

        is_binary(group) and group != "" and is_list(groups) ->
          [group | groups]

        true ->
          :bad
      end

    case gids do
      :bad ->
        {:error, :bad_dest}

      list ->
        if Enum.any?(list, &(not is_binary(&1) or &1 == "")) do
          {:error, :bad_dest}
        else
          live = MapSet.new(Membership.ids(tenant_id, session_id))

          ids =
            list
            |> Enum.flat_map(&Groups.members(tenant_id, session_id, &1))
            |> Enum.uniq()
            |> Enum.filter(&MapSet.member?(live, &1))

          if ids == [] do
            {:error, :empty_dest}
          else
            {:ok, ids}
          end
        end
    end
  end

  defp resolve_role_attr(tenant_id, session_id, role, attr) do
    members = Membership.list(tenant_id, session_id)

    ids =
      members
      |> Enum.filter(fn {_id, meta} ->
        match_role?(meta, role) and match_attr?(meta, attr)
      end)
      |> Enum.map(fn {id, _} -> id end)

    if ids == [] do
      {:error, :empty_dest}
    else
      {:ok, ids}
    end
  end

  defp resolve_except(tenant_id, session_id, actor_id) do
    ids =
      tenant_id
      |> Membership.ids(session_id)
      |> Enum.reject(&(&1 == actor_id))

    if ids == [] do
      {:error, :empty_dest}
    else
      {:ok, ids}
    end
  end

  defp match_role?(_meta, nil), do: true

  defp match_role?(meta, role) do
    to_string(Map.get(meta, :role) || Map.get(meta, "role")) == to_string(role)
  end

  defp match_attr?(_meta, nil), do: true

  defp match_attr?(meta, attr) when is_map(attr) do
    Enum.all?(attr, fn {k, v} ->
      key = if is_atom(k), do: k, else: String.to_existing_atom(to_string(k))
      Map.get(meta, key) == v || Map.get(meta, to_string(k)) == v
    end)
  rescue
    ArgumentError -> false
  end

  defp match_attr?(_, _), do: false
end
