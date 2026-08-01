defmodule Tymeslot.Integrations.Calendar.Defaults do
  @moduledoc """
  Shared helpers for determining default booking calendars within an integration.

  Centralizes logic for deriving a reasonable default calendar ID from
  provider-specific calendar lists and fields. Keep this module dependency-free
  from other contexts to allow easy reuse.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @doc """
  Determine best default calendar within an integration struct.

  Priority:
  - If calendar_list present: primary -> selected -> first, considering
    only entries eligible for booking (not read-only) — see
    `default_booking_calendar/2`, whose read ladder this mirrors so the id
    persisted here is never one the read path would then refuse to honour
  - Else provider fallback: google => "primary", outlook => "default"
  - Else first calendar_paths entry
  """
  @spec resolve_default_calendar_id(CalendarIntegrationSchema.t()) :: String.t() | nil
  def resolve_default_calendar_id(%CalendarIntegrationSchema{} = integration) do
    calendars = integration.calendar_list || []

    case pick_from_list(calendars) do
      nil -> provider_default(integration) || first_path(integration)
      id -> id
    end
  end

  defp pick_from_list(calendars) do
    if is_list(calendars) and calendars != [] do
      eligible = eligible_for_booking(calendars)
      primary_id(eligible) || selected_id(eligible) || first_id_from_list(eligible)
    else
      nil
    end
  end

  defp provider_default(%{provider: "google"}), do: "primary"
  defp provider_default(%{provider: "outlook"}), do: "default"
  defp provider_default(_integration), do: nil

  defp first_path(%{calendar_paths: paths}) when is_list(paths) and paths != [],
    do: List.first(paths)

  defp first_path(_integration), do: nil

  @doc """
  Find provider-primary calendar ID from a calendar list.
  """
  @spec primary_id(list()) :: String.t() | nil
  def primary_id(calendars) when is_list(calendars) do
    calendars
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.find(& &1.primary)
    |> calendar_id()
  end

  def primary_id(_calendars), do: nil

  @doc """
  Find first selected calendar ID from a calendar list.
  """
  @spec selected_id(list()) :: String.t() | nil
  def selected_id(calendars) when is_list(calendars) do
    calendars
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.find(& &1.selected)
    |> calendar_id()
  end

  def selected_id(_calendars), do: nil

  @doc """
  Get the first calendar ID from a calendar list.
  """
  @spec first_id_from_list(list()) :: String.t() | nil
  def first_id_from_list(calendars) when is_list(calendars) do
    calendars
    |> Enum.map(&CalendarEntry.normalize/1)
    |> List.first()
    |> calendar_id()
  end

  def first_id_from_list(_calendars), do: nil

  @doc """
  Resolves the calendar entry that booking currently targets within `calendar_list`:
  the entry matching `booking_id`, else the provider-primary entry, else the
  first *selected* entry, else the first entry. Returns `nil` when the
  calendar list holds no eligible entry.

  All four tiers are restricted to calendars eligible for booking — i.e. not
  read-only — so a caller can never accidentally hand back a calendar the
  integration cannot write to, whether that's via a stale `booking_id`, a
  provider `primary` flag, or the final "first" fallback. A `booking_id`
  that matches a read-only (or now-removed) entry is treated the same as no
  match at all and falls through the rest of the ladder, rather than being
  returned as-is: handing back a stale id that no longer resolves to a
  usable calendar is worse than falling through to a calendar that actually
  works.

  Takes the calendar list and target id directly, rather than a whole
  integration, so callers that only want to resolve a default among a subset
  of calendars (e.g. already-selected ones) don't need to fabricate a struct.
  """
  @spec default_booking_calendar([CalendarEntry.t()] | nil, String.t() | nil) ::
          CalendarEntry.t() | nil
  def default_booking_calendar(calendar_list, booking_id) do
    eligible = eligible_for_booking(calendar_list || [])

    by_booking_id = booking_id && Enum.find(eligible, &(&1.id == booking_id))

    by_booking_id || Enum.find(eligible, & &1.primary) || Enum.find(eligible, & &1.selected) ||
      List.first(eligible)
  end

  defp calendar_id(nil), do: nil
  defp calendar_id(%CalendarEntry{} = entry), do: entry.id || entry.path

  @doc """
  Restricts a calendar list to entries eligible as a booking target: not
  read-only. Booking must write to the target calendar, so a read-only
  entry can never be resolved as a default regardless of its
  primary/selected/id-match status. Centralized here so every ladder in
  this module — and any other caller building its own primary/selected/first
  ladder over a discovered calendar list — applies the same rule instead of
  each caller remembering to pre-filter.
  """
  @spec eligible_for_booking([CalendarEntry.t() | map()]) :: [CalendarEntry.t()]
  def eligible_for_booking(calendars) do
    calendars
    |> Enum.map(&CalendarEntry.normalize/1)
    |> Enum.reject(& &1.read_only)
  end

  @doc """
  Resolves the calendar entry that booking is *confirmed* to target: the
  entry matching `default_booking_calendar_id`, else the provider-primary
  entry. Returns `nil` when neither is present — deliberately narrower than
  `default_booking_calendar/2`, which also falls back to the first/selected
  entry.

  Both tiers are restricted to eligible (not read-only) calendars, for the
  same reason `default_booking_calendar/2` is: a summary must not claim a
  read-only calendar as the confirmed booking target.

  Use this for display-only summaries that must only name a booking target
  once one is actually confirmed; it must not guess "first calendar" the way
  the calendar grid's editor default does, which would claim an
  unconfigured integration books into an arbitrary calendar before the user
  has chosen one.
  """
  @spec confirmed_booking_calendar(%{
          :calendar_list => [CalendarEntry.t()] | nil,
          :default_booking_calendar_id => String.t() | nil,
          optional(atom()) => term()
        }) :: CalendarEntry.t() | nil
  def confirmed_booking_calendar(%{calendar_list: calendar_list} = integration) do
    eligible = eligible_for_booking(calendar_list || [])
    booking_id = Map.get(integration, :default_booking_calendar_id)

    (booking_id && Enum.find(eligible, &(&1.id == booking_id))) ||
      Enum.find(eligible, & &1.primary)
  end
end
