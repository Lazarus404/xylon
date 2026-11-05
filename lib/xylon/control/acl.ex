defmodule Xylon.Control.Acl do
  @moduledoc """
  Topic labels and capability checks for join, inject, record, and sessions list.

  ## What problem this solves

  Multi-topic rooms (chat, alerts, moderation notices) need a configured map
  from topic names to datachannel labels, plus coarse ACL on who may inject,
  who may mutate or send to named groups, who may record, and who may list
  live sessions. ACL reads `control[:topics]` and the authenticated
  `capabilities` list or map without interpreting backend-specific semantics.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon control-plane API.

  ## Examples

      iex> ctx = %Xylon.Control.Context{
      ...>   tenant_id: "t", session_id: "s", participant_id: "a",
      ...>   capabilities: ["inject"]
      ...> }
      iex> Xylon.Control.Acl.allow_inject?(ctx, "chat")
      true
      iex> narrow = %{ctx | capabilities: ["inject:alerts"]}
      iex> Xylon.Control.Acl.allow_inject?(narrow, "chat")
      false
  """

  alias Xylon.Control.Auth
  alias Xylon.Control.Context

  @doc "Configured topics map: name -> %{label: ..., session_id: optional}."
  @spec topics() :: map()
  def topics do
    case Keyword.get(Auth.config(), :topics, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Resolves a topic name to a datachannel label (default: topic name)."
  @spec label_for(binary()) :: binary() | nil
  def label_for(topic) when is_binary(topic) do
    case Map.get(topics(), topic) do
      %{label: label} when is_binary(label) -> label
      %{"label" => label} when is_binary(label) -> label
      meta when is_map(meta) -> topic
      nil ->
        if topics() == %{}, do: topic, else: nil
    end
  end

  @doc """
  True when join may open the given label.

  Empty topics config allows any label. Otherwise label must match a configured topic.
  """
  @spec allow_join_label?(Context.t(), binary()) :: boolean()
  def allow_join_label?(_ctx, label) when is_binary(label) do
    case topics() do
      map when map == %{} -> true
      map -> Enum.any?(map, fn {_name, meta} -> topic_label(meta) == label end)
    end
  end

  @doc """
  Inject allow: optional capability `"inject"` or `"inject:<label>"` when capabilities
  are a non-empty list; empty/missing capabilities allow (lab). Maps consult `"inject"`.
  """
  @spec allow_inject?(Context.t(), binary() | nil) :: boolean()
  def allow_inject?(%Context{capabilities: caps}, label) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        "inject" in caps or (is_binary(label) and ("inject:" <> label) in caps)

      is_map(caps) ->
        Map.get(caps, "inject") == true or Map.get(caps, :inject) == true

      true ->
        false
    end
  end

  @doc """
  True when the actor may create/delete groups or change membership.

  Empty capabilities allow (lab). List: `"groups:mutate"` or `"groups:mutate:<gid>"`.
  Map: `"groups_mutate"` / `:groups_mutate` true.
  """
  @spec allow_groups_mutate?(Context.t(), binary() | nil) :: boolean()
  def allow_groups_mutate?(%Context{capabilities: caps}, group_id \\ nil) do
    allow_groups_cap?(caps, "groups:mutate", "groups_mutate", :groups_mutate, group_id)
  end

  @doc """
  True when the actor may resolve/inject to a named group destination.

  Empty capabilities allow (lab). List: `"groups:send"` or `"groups:send:<gid>"`.
  Map: `"groups_send"` / `:groups_send` true.
  """
  @spec allow_groups_send?(Context.t(), binary() | nil) :: boolean()
  def allow_groups_send?(%Context{capabilities: caps}, group_id \\ nil) do
    allow_groups_cap?(caps, "groups:send", "groups_send", :groups_send, group_id)
  end

  @doc """
  True when the actor may mutate per-sender egress routes.

  Empty capabilities allow (lab). List: `"routes:mutate"`. Map: `"routes_mutate"` /
  `:routes_mutate` true.
  """
  @spec allow_routes_mutate?(Context.t()) :: boolean()
  def allow_routes_mutate?(%Context{capabilities: caps}) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        "routes:mutate" in caps

      is_map(caps) ->
        Map.get(caps, "routes_mutate") == true or Map.get(caps, :routes_mutate) == true

      true ->
        false
    end
  end

  @doc """
  True when the actor may start/stop/get room recording.

  Empty capabilities allow (lab). List: `"record"`. Map: `"record"` / `:record` true.
  """
  @spec allow_record?(Context.t()) :: boolean()
  def allow_record?(%Context{capabilities: caps}) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        "record" in caps

      is_map(caps) ->
        Map.get(caps, "record") == true or Map.get(caps, :record) == true

      true ->
        false
    end
  end

  @doc """
  True when the actor may list live sessions for a tenant.

  Empty capabilities allow (lab). List: `"sessions"`. Map: `"sessions"` /
  `:sessions` true.
  """
  @spec allow_sessions?(Context.t()) :: boolean()
  def allow_sessions?(%Context{capabilities: caps}) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        "sessions" in caps

      is_map(caps) ->
        Map.get(caps, "sessions") == true or Map.get(caps, :sessions) == true

      true ->
        false
    end
  end

  @doc """
  True when the actor may read fleet summary/nodes for a tenant.

  Empty capabilities allow (lab). List: `"fleet"`. Map: `"fleet"` / `:fleet`
  true.
  """
  @spec allow_fleet?(Context.t()) :: boolean()
  def allow_fleet?(%Context{capabilities: caps}) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        "fleet" in caps

      is_map(caps) ->
        Map.get(caps, "fleet") == true or Map.get(caps, :fleet) == true

      true ->
        false
    end
  end

  @doc "True when `dest` is a group filter map (`group` / `groups` keys)."
  @spec group_dest?(term()) :: boolean()
  def group_dest?(dest) when is_map(dest) do
    Map.has_key?(dest, "group") or Map.has_key?(dest, :group) or
      Map.has_key?(dest, "groups") or Map.has_key?(dest, :groups)
  end

  def group_dest?(_), do: false

  @doc """
  All group ids referenced by a group dest map (`group` plus `groups` list).

  Empty strings and non-binaries are dropped. Order preserved; duplicates kept
  so callers can require a send grant for each reference.
  """
  @spec group_dest_ids(map()) :: [binary()]
  def group_dest_ids(dest) when is_map(dest) do
    single =
      case Map.get(dest, "group") || Map.get(dest, :group) do
        id when is_binary(id) and id != "" -> [id]
        _ -> []
      end

    many =
      case Map.get(dest, "groups") || Map.get(dest, :groups) do
        list when is_list(list) ->
          Enum.filter(list, &(is_binary(&1) and &1 != ""))

        _ ->
          []
      end

    single ++ many
  end

  @doc """
  True when the actor may send/resolve to every group id in `dest`.

  Unscoped `"groups:send"` (or map true) allows any group dest. Scoped caps
  must cover **each** id in `{group}` / `{groups}` (no first-id-only shortcut).
  Malformed empty id lists fall back to `allow_groups_send?(ctx, nil)`.
  """
  @spec allow_groups_send_dest?(Context.t(), map()) :: boolean()
  def allow_groups_send_dest?(%Context{} = ctx, dest) when is_map(dest) do
    case group_dest_ids(dest) do
      [] -> allow_groups_send?(ctx, nil)
      ids -> Enum.all?(ids, &allow_groups_send?(ctx, &1))
    end
  end

  defp allow_groups_cap?(caps, list_prefix, map_str, map_atom, group_id) do
    cond do
      caps in [nil, [], %{}] ->
        true

      is_list(caps) ->
        list_prefix in caps or
          (is_binary(group_id) and (list_prefix <> ":" <> group_id) in caps)

      is_map(caps) ->
        Map.get(caps, map_str) == true or Map.get(caps, map_atom) == true

      true ->
        false
    end
  end

  defp topic_label(%{label: label}) when is_binary(label), do: label
  defp topic_label(%{"label" => label}) when is_binary(label), do: label
  defp topic_label(_), do: nil
end
