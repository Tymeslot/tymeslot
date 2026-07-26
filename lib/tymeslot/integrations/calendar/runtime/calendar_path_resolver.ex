defmodule Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver do
  @moduledoc """
  Resolves a CalDAV-style calendar path from a calendar integration.

  When the integration carries a `default_booking_calendar_id` and a
  `calendar_list`, the matching calendar's `path` is returned. Otherwise
  the first entry in `calendar_paths` is used as a backwards-compatible
  fallback. The matching is URI-safe so encoded and decoded forms compare
  equal.
  """

  alias Tymeslot.Utils.UriUtils

  @doc """
  Returns the calendar path that should be used for booking on the given
  integration, or `nil` if no usable path is configured.
  """
  @spec resolve(map()) :: String.t() | nil
  def resolve(integration) do
    calendar_id = integration.default_booking_calendar_id
    calendar_list = integration.calendar_list

    if calendar_id && calendar_list != nil && calendar_list != [] do
      find_calendar_path_by_id(calendar_list, calendar_id)
    else
      List.first(integration.calendar_paths || [])
    end
  end

  defp find_calendar_path_by_id(calendar_list, calendar_id) do
    calendar =
      calendar_list
      |> Enum.map(&normalize_calendar/1)
      |> Enum.find(&UriUtils.uri_safe_match?(&1.id, calendar_id))

    # CalDAV discovery historically stored only `id` (the href). Fall back to
    # it so existing integrations whose `calendar_list` entries have a null
    # `path` can still resolve a booking target.
    calendar && (calendar.path || calendar.id)
  end

  # `calendar_list` entries are string-keyed once they have been through the
  # JSONB column, but arrive atom-keyed straight from discovery. This is the one
  # place that answers "which key type?"; everything below reads atoms.
  defp normalize_calendar(calendar) do
    %{
      id: Map.get(calendar, "id") || Map.get(calendar, :id),
      path: Map.get(calendar, "path") || Map.get(calendar, :path)
    }
  end
end
