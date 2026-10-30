defmodule TymeslotWeb.Dashboard.CalendarGrid.WriteOutcomeMessages do
  @moduledoc """
  The copy the dashboard flashes when a calendar grid write answers: an
  event update reverted, an event or a whole series moved to another
  calendar (or not), an ad-hoc meeting refused, a video link left unchanged.

  Each function maps the reason a write reports to what the organiser is
  told; `TymeslotWeb.Dashboard.CalendarEventHandlers` picks the flash and
  tells the grid. The wording the grid itself shares with the edit flow
  lives in `TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.RoomCreationError
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  @doc "What the organiser is told when an event update failed and was reverted."
  @spec update_failed_message(term()) :: String.t()
  # A refusal the domain made names its own reason; everything else is a
  # provider failure the organiser can do nothing about. The scoped edits of
  # a recurring series refuse before anything is written, so each of their
  # reasons says what the organiser can do instead (see
  # `Tymeslot.CalendarGrid.SeriesEdit`).
  def update_failed_message(:value_type_change) do
    dgettext(
      "dashboard_calendar_events",
      "Events of a repeating series cannot be switched between all-day and timed here. Please make this change in your calendar app."
    )
  end

  def update_failed_message(reason) when reason in [:unsupported_scope, :rule_removal] do
    dgettext(
      "dashboard_calendar_events",
      "That change cannot be made to the events you chose. A repeat rule can only be changed for all events, or this and following events, and cannot be removed here."
    )
  end

  def update_failed_message(:rule_pins_occurrences) do
    dgettext(
      "dashboard_calendar_events",
      "This series repeats on fixed days, such as the second Monday of the month, so it cannot be moved like this. Please make this change in your calendar app."
    )
  end

  def update_failed_message(:unsupported_rule) do
    dgettext(
      "dashboard_calendar_events",
      "This series' repeat rule cannot be split here. Please make this change in your calendar app."
    )
  end

  # What is left of a count is counted again when the change is written, from
  # the series as it is then, which a sync may have changed since the scope
  # was chosen. The prompt offered that scope, so these say the series moved
  # on under the organiser rather than repeating why a scope is not offered.
  def update_failed_message(:ends_before) do
    dgettext(
      "dashboard_calendar_events",
      "This series changed while you were editing it, and nothing is left of it from this event on. Nothing was saved."
    )
  end

  # Either the series' first start can no longer be read, or a sync cleared
  # its rule while it is still marked a series: both leave nothing to count
  # from.
  def update_failed_message(:start_unknown) do
    dgettext(
      "dashboard_calendar_events",
      "This series changed while you were editing it, so the events left in it can no longer be counted. Nothing was saved. Refresh the calendar and try again."
    )
  end

  def update_failed_message(:rule_not_supported_by_outlook),
    do: EditWorkflow.rule_not_supported_by_outlook_message()

  def update_failed_message(:day_missing_in_some_months),
    do: EditWorkflow.month_end_refused_message()

  def update_failed_message(:not_organiser), do: EditWorkflow.not_organiser_message()

  def update_failed_message(reason)
      when reason in [:unaddressable_occurrence, :unreadable_timing, :not_recurring],
      do: EditWorkflow.unmatched_series_message()

  def update_failed_message(_reason),
    do: dgettext("dashboard_calendar_events", "Failed to update event - changes reverted")

  @doc "The flash level and message after an event moved to another calendar, by what became of the original."
  @spec moved_flash(nil | :queued_delete | :left_behind | :unknown) ::
          {:info | :warning, String.t()}
  def moved_flash(nil),
    do: {:info, dgettext("dashboard_calendar_events", "Event moved to the new calendar.")}

  def moved_flash(:queued_delete) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar. The original will be removed on the next sync."
     )}
  end

  def moved_flash(:left_behind) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the original could not be removed. Please delete it from its original calendar."
     )}
  end

  # Something failed once the new calendar had accepted the event, so it is
  # there, and whether the original is too cannot be said.
  def moved_flash(:unknown) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the move did not finish. Please check its original calendar and delete the original if it is still there."
     )}
  end

  @doc "The flash level and message after a whole series moved to `calendar`."
  @spec series_moved_flash(nil | :left_behind, String.t()) :: {:info | :warning, String.t()}
  def series_moved_flash(nil, calendar) do
    {:info,
     dgettext("dashboard_calendar_events", "The series was moved to %{calendar}.",
       calendar: calendar
     )}
  end

  def series_moved_flash(:left_behind, calendar) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "The series was copied to %{calendar}, but the original series could not be removed. Please delete it from its original calendar.",
       calendar: calendar
     )}
  end

  @doc "What the organiser is told when an event could not be moved."
  @spec move_failed_message(term()) :: String.t()
  def move_failed_message(:recurring_event), do: EditWorkflow.recurring_move_refused_message()

  def move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the event. It is still on its original calendar."
    )
  end

  @doc "What the organiser is told when an ad-hoc meeting could not be created."
  @spec ad_hoc_failed_message(term()) :: String.t()
  # The reason is a domain term, never copy: an atom such as `:time_conflict`
  # would otherwise reach the flash verbatim. `CreateAdHoc`'s own refusals are
  # atoms `BookingErrorMessage` renders, and anything it does not recognise
  # falls back to a generic sentence there.
  def ad_hoc_failed_message(:time_conflict) do
    dgettext(
      "dashboard_calendar_events",
      "You already have a meeting at this time. Please choose a different time."
    )
  end

  def ad_hoc_failed_message(reason), do: BookingErrorMessage.message(reason)

  @doc "What the organiser is told when an event's video link could not be changed."
  @spec video_failed_message(term()) :: String.t()
  def video_failed_message(:meet_link_pending) do
    dgettext(
      "dashboard_calendar_events",
      "Google Calendar added Google Meet to the event but has not returned its link yet. Choose Google Meet again to fetch it."
    )
  end

  def video_failed_message(:linked_to_booking),
    do: EditWorkflow.booking_video_refused_message()

  def video_failed_message(:missing_meeting_url) do
    dgettext(
      "dashboard_calendar_events",
      "The video provider did not return a meeting link, so the video link was not changed."
    )
  end

  # A provider that refuses to create rooms because of a setting on its own
  # server says which one, and that is what the organiser has to change; the
  # same words their video integration's row shows. Anything else is a failure
  # they can only try again.
  def video_failed_message({:configuration_error, code}) when is_atom(code) do
    if code in RoomCreationError.codes(),
      do: RoomCreationError.message(code),
      else: video_failed_message(:unknown)
  end

  def video_failed_message(_reason),
    do:
      dgettext("dashboard_calendar_events", "Could not change the video link - changes reverted")
end
