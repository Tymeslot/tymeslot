defmodule Tymeslot.CalendarGrid.EffectiveVisibility do
  @moduledoc """
  What the calendar hides, from the organiser's two hidden stores
  (accounts on the calendar preferences, calendars on their appearances)
  and the active calendar set, if any.

  With no set the stores are the answer, exactly as before sets existed.
  With a set, the set alone decides and the stores are kept untouched for
  when it is left: an account with no member is hidden; an account with a
  whole-account member shows everything; any other account hides each
  synced calendar that is not a member, a calendar connected after the set
  was saved included. Bookings carry no integration id, so neither ever
  hides them.

  `resolve/4` is pure, for the surface, which already holds every input;
  `for_user/1` loads them, for callers outside it.
  """

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.EventWindow
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.Management

  defstruct hidden_integration_ids: [], hidden_calendar_keys: MapSet.new(), active_set: nil

  @type t :: %__MODULE__{
          hidden_integration_ids: [integer()],
          hidden_calendar_keys: MapSet.t({integer(), String.t()}),
          active_set: map() | nil
        }

  @doc "The hidden accounts and calendar keys for the stores and the active set."
  @spec resolve([integer()], MapSet.t(), [map()], map() | nil) :: t()
  def resolve(manual_ids, manual_keys, _integrations, nil),
    do: %__MODULE__{hidden_integration_ids: manual_ids, hidden_calendar_keys: manual_keys}

  def resolve(_manual_ids, _manual_keys, integrations, %{members: members} = set) do
    by_integration = Enum.group_by(members, & &1.integration_id, & &1.calendar_id)

    {ids, keys} =
      Enum.reduce(integrations, {[], MapSet.new()}, fn integration, {ids, keys} ->
        case Map.fetch(by_integration, integration.id) do
          :error -> hide_whole({ids, keys}, integration)
          {:ok, calendar_ids} -> hide_unlisted({ids, keys}, integration, calendar_ids)
        end
      end)

    %__MODULE__{
      hidden_integration_ids: Enum.reverse(ids),
      hidden_calendar_keys: keys,
      active_set: set
    }
  end

  @doc "Loads the organiser's stores, active integrations and active set, and resolves them."
  @spec for_user(integer()) :: t()
  def for_user(user_id) do
    preferences = CalendarPreferencesQueries.get_or_create(user_id)
    manual_keys = user_id |> Appearance.list_for_user() |> Appearance.hidden_keys()

    resolve(
      preferences.hidden_integration_ids,
      manual_keys,
      Management.list_active_calendar_integrations(user_id),
      CalendarSets.active(user_id, preferences)
    )
  end

  @doc "`events` without those it hides (see `EventWindow.reject_hidden/3`)."
  @spec reject([map()], t()) :: [map()]
  def reject(events, %__MODULE__{} = visibility),
    do:
      EventWindow.reject_hidden(
        events,
        visibility.hidden_integration_ids,
        visibility.hidden_calendar_keys
      )

  # A whole-account member (nil) hides nothing in the account. An account
  # whose members all name calendars it no longer syncs shows nothing, so it
  # is hidden whole.
  # The account's calendars are keyed as hidden too, so the rail never shows
  # one ticked under an unticked account.
  defp hide_whole({ids, keys}, integration) do
    keys =
      integration
      |> CalendarDirectory.synced_entries()
      |> Enum.reduce(keys, &MapSet.put(&2, {integration.id, &1.id}))

    {[integration.id | ids], keys}
  end

  defp hide_unlisted({ids, keys}, integration, calendar_ids) do
    synced = CalendarDirectory.synced_entries(integration)

    cond do
      nil in calendar_ids ->
        {ids, keys}

      not Enum.any?(synced, &(&1.id in calendar_ids)) ->
        hide_whole({ids, keys}, integration)

      true ->
        {ids, Enum.reduce(synced, keys, &hide_unless_member(&2, integration, &1, calendar_ids))}
    end
  end

  defp hide_unless_member(keys, integration, entry, calendar_ids) do
    if entry.id in calendar_ids, do: keys, else: MapSet.put(keys, {integration.id, entry.id})
  end
end
