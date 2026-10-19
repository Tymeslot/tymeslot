defmodule Tymeslot.CalendarGrid.CalendarSets do
  @moduledoc """
  The organiser's calendar sets: up to nine named groups of calendars, each
  on the digit that applies it (1 to 9; 0 leaves the active set).

  A set is an overlay on the organiser's own hidden choices, never a
  rewrite of them: applying one writes only `active_calendar_set_id` on the
  calendar preferences, and `EffectiveVisibility` decides what shows. Every
  function takes the acting organiser and finds their set by position, so a
  position names nothing of another organiser's (`{:error, :not_found}`).

  A member is `%{integration_id, calendar_id}`; `calendar_id` nil stands for
  a whole account, used for an account without a calendar list. The member
  rules (`members_from/2`, `toggle_account/2`, `toggle_calendar/3`) are pure,
  for the rail's ticks while a set is active.
  """

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.CalendarSetQueries
  alias Tymeslot.CalendarGrid.CalendarSetSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.Management

  @type set :: CalendarSetSchema.t()
  @type member :: %{integration_id: integer(), calendar_id: String.t() | nil}

  @doc "The organiser's sets, by position."
  @spec list(integer()) :: [set()]
  def list(user_id), do: CalendarSetQueries.list_for_user(user_id)

  @doc "The active set named by `preferences`, or nil."
  @spec active(integer(), map()) :: set() | nil
  def active(user_id, preferences), do: active_in(list(user_id), preferences)

  @doc "The active set among `sets` (already listed for the same organiser), or nil."
  @spec active_in([set()], map()) :: set() | nil
  def active_in(_sets, %{active_calendar_set_id: nil}), do: nil
  def active_in(sets, %{active_calendar_set_id: id}), do: Enum.find(sets, &(&1.id == id))

  @doc "Saves a new set at the lowest free position; `{:error, :limit}` once nine exist."
  @spec create(integer(), String.t(), [member()]) ::
          {:ok, set()} | {:error, :limit | Ecto.Changeset.t()}
  def create(user_id, name, members) do
    taken = MapSet.new(list(user_id), & &1.position)

    case Enum.find(CalendarSetSchema.positions(), &(not MapSet.member?(taken, &1))) do
      nil ->
        {:error, :limit}

      position ->
        CalendarSetQueries.insert(%{
          user_id: user_id,
          name: name,
          position: position,
          members: members |> plain() |> owned(user_id)
        })
    end
  end

  @doc "Renames the organiser's set on `position`."
  @spec rename(integer(), integer(), String.t()) ::
          {:ok, set()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(user_id, position, name),
    do: with_set(user_id, position, &CalendarSetQueries.update(&1, %{name: name}))

  @doc "Deletes the organiser's set on `position`; if it was active, no set is (by the foreign key)."
  @spec delete(integer(), integer()) :: {:ok, set()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete(user_id, position), do: with_set(user_id, position, &CalendarSetQueries.delete/1)

  @doc "Replaces the members of the organiser's set on `position`."
  @spec put_members(integer(), integer(), [member()]) ::
          {:ok, set()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_members(user_id, position, members),
    do:
      with_set(
        user_id,
        position,
        &CalendarSetQueries.update_members(&1, members |> plain() |> owned(user_id))
      )

  @doc "Makes the set on `position` the active one; 0 leaves the active set."
  @spec activate(integer(), integer()) ::
          {:ok, set() | nil} | {:error, :not_found | Ecto.Changeset.t()}
  def activate(user_id, 0) do
    with {:ok, _preferences} <-
           CalendarPreferencesQueries.upsert(user_id, %{active_calendar_set_id: nil}),
         do: {:ok, nil}
  end

  def activate(user_id, position) do
    with_set(user_id, position, fn set ->
      with {:ok, _preferences} <-
             CalendarPreferencesQueries.upsert(user_id, %{active_calendar_set_id: set.id}),
           do: {:ok, set}
    end)
  end

  @doc """
  The members for what shows now (`shown` holds the hidden accounts and
  calendar keys): each synced calendar not hidden, or the whole account for
  a shown account without a calendar list.
  """
  @spec members_from([map()], %{
          :hidden_integration_ids => [integer()],
          :hidden_calendar_keys => MapSet.t(),
          optional(atom()) => any()
        }) ::
          [member()]
  def members_from(integrations, %{hidden_integration_ids: ids, hidden_calendar_keys: keys}) do
    integrations
    |> Enum.reject(&(&1.id in ids))
    |> Enum.flat_map(fn integration ->
      integration
      |> all_members()
      |> Enum.reject(&MapSet.member?(keys, {&1.integration_id, &1.calendar_id}))
    end)
  end

  @doc "Takes a shown account out of the members, or puts a hidden one in whole."
  @spec toggle_account([map()], map()) :: [member()]
  def toggle_account(members, %{id: id} = integration) do
    members = plain(members)

    if Enum.any?(members, &(&1.integration_id == id)),
      do: Enum.reject(members, &(&1.integration_id == id)),
      else: members ++ all_members(integration)
  end

  @doc """
  Takes one calendar out of the members or puts it in. A whole-account
  member becomes every synced calendar but this one; a calendar the
  integration does not list is ignored.
  """
  @spec toggle_calendar([map()], map(), String.t()) :: [member()]
  def toggle_calendar(members, %{id: id} = integration, calendar_id) do
    members = plain(members)
    member = %{integration_id: id, calendar_id: calendar_id}

    cond do
      %{integration_id: id, calendar_id: nil} in members ->
        Enum.reject(members, &(&1.integration_id == id)) ++
          Enum.reject(all_members(integration), &(&1 == member))

      member in members ->
        List.delete(members, member)

      Enum.any?(CalendarDirectory.synced_entries(integration), &(&1.id == calendar_id)) ->
        members ++ [member]

      true ->
        members
    end
  end

  defp with_set(user_id, position, fun) when is_integer(position) do
    case CalendarSetQueries.get_for_user(user_id, position) do
      %CalendarSetSchema{} = set -> fun.(set)
      nil -> {:error, :not_found}
    end
  end

  defp with_set(_user_id, _position, _fun), do: {:error, :not_found}

  # Every calendar of an integration as members: its synced calendars, or
  # the whole account when it lists none.
  defp all_members(%{id: id} = integration) do
    case CalendarDirectory.synced_entries(integration) do
      [] -> [%{integration_id: id, calendar_id: nil}]
      entries -> Enum.map(entries, &%{integration_id: id, calendar_id: &1.id})
    end
  end

  # Members naming an integration the organiser does not have (removed, or
  # another organiser's) are never stored.
  defp owned(members, user_id) do
    ids = user_id |> Management.list_active_calendar_integrations() |> MapSet.new(& &1.id)
    Enum.filter(members, &MapSet.member?(ids, &1.integration_id))
  end

  defp plain(members), do: members |> Enum.map(&CalendarSetSchema.member_params/1) |> Enum.uniq()
end
