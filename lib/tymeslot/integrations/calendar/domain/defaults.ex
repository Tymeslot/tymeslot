defmodule Tymeslot.Integrations.Calendar.Defaults do
  @moduledoc """
  Shared helpers for determining default booking calendars within an integration.

  Centralizes logic for deriving a reasonable default calendar ID from
  provider-specific calendar lists and fields. Keep this module dependency-free
  from other contexts to allow easy reuse.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Utils.UriUtils

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
  Resolves the calendar entry bookings on this integration are written to, and
  whether it can take them.

  Mirrors the providers' write path rather than the booking ladder: when
  `default_booking_calendar_id` is set, bookings go to that calendar and nowhere
  else, so it is the answer even when it is read-only (`{:read_only, entry}`)
  and `:none` when it is no longer listed. Only with no id set does the
  provider-primary entry stand in. It never guesses a selected or first
  calendar, so an unconfigured integration answers `:none`.

  Use this for display-only summaries: unlike `default_booking_calendar/2`, it
  does not skip read-only calendars, because a summary has to say where
  bookings actually go, including when that is somewhere they will fail.
  """
  @spec booking_target(%{
          :calendar_list => [CalendarEntry.t()] | nil,
          :default_booking_calendar_id => String.t() | nil,
          optional(atom()) => term()
        }) :: {:ok, CalendarEntry.t()} | {:read_only, CalendarEntry.t()} | :none
  def booking_target(%{calendar_list: calendar_list} = integration) do
    calendars = Enum.map(calendar_list || [], &CalendarEntry.normalize/1)

    target =
      case Map.get(integration, :default_booking_calendar_id) do
        nil -> Enum.find(calendars, & &1.primary)
        booking_id -> Enum.find(calendars, &UriUtils.uri_safe_match?(&1.id, booking_id))
      end

    case target do
      nil -> :none
      %CalendarEntry{read_only: true} = entry -> {:read_only, entry}
      entry -> {:ok, entry}
    end
  end
end
