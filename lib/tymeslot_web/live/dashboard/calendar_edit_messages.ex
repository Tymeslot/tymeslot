defmodule TymeslotWeb.Dashboard.CalendarEditMessages do
  @moduledoc """
  What the calendar tells the organiser when a change is refused
  (`Tymeslot.CalendarGrid.EditGuard`), when a delete or a create fails, and when
  changes made while a whole series was saving were dropped, so every part
  of the calendar words the same refusal alike.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The flash level and words for a refusal."
  @spec refusal(term()) :: {:error | :warning, String.t()}
  def refusal({:error, :unauthorized}),
    do:
      {:error,
       dgettext("dashboard_calendar_events", "You don't have permission to modify this event")}

  def refusal({:error, :read_only}),
    do:
      {:error,
       dgettext(
         "dashboard_calendar_events",
         "This calendar is read-only. Events on it can't be changed from Tymeslot."
       )}

  def refusal({:error, :rate_limited, _message}),
    do: {:warning, dgettext("dashboard_calendar_events", "Too many edits. Please wait a moment.")}

  def refusal({:error, :group_booking}), do: {:warning, seat_lock_message()}

  def refusal({:error, :syncing}),
    do:
      {:warning,
       dgettext(
         "dashboard_calendar_events",
         "Syncing with your calendar. Open the event to change the whole series."
       )}

  def refusal({:error, :booking}),
    do:
      {:warning,
       dgettext("dashboard_calendar", "This is a booking. Reschedule or cancel it from Bookings.")}

  @doc """
  Why an event a group meeting with live seats sits on cannot be changed
  here: the one wording the refusal flash, the locked badge and the event
  modal share.
  """
  @spec seat_lock_message() :: String.t()
  def seat_lock_message do
    dgettext(
      "dashboard_calendar_events",
      "This is a group booking. Move it, cancel it or change who attends from the meeting instead."
    )
  end

  @doc "A write to a whole series would race a change of another of its events still saving."
  @spec series_saving_message() :: String.t()
  def series_saving_message do
    dgettext(
      "dashboard_calendar_events",
      "A change to this series is still saving. Please make this change once it has saved."
    )
  end

  @doc "Exchange has no scoped delete, so none of its series can be deleted here."
  @spec recurring_delete_refused_message() :: String.t()
  def recurring_delete_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring Exchange events cannot be deleted here yet. Please delete this one in your calendar app."
    )
  end

  @doc "The event is gone, but the meeting it belonged to could not be cancelled."
  @spec deleted_but_meeting_not_cancelled_message() :: String.t()
  def deleted_but_meeting_not_cancelled_message do
    dgettext(
      "dashboard_calendar_events",
      "Event deleted, but meeting cancellation failed. The attendee may not be notified."
    )
  end

  @doc "The event is gone, but the cancellation for its attendees could not be sent."
  @spec deleted_but_attendees_not_notified_message() :: String.t()
  def deleted_but_attendees_not_notified_message,
    do:
      dgettext(
        "dashboard_calendar_events",
        "Event deleted, but the attendees could not be notified."
      )

  @doc """
  Why a delete failed. A queued delete will be replayed on the next sync;
  anything else is final. Nobody is notified of a delete that has not
  happened, which a queued one that was meant to notify says, since its
  retry sends nothing.
  """
  @spec delete_failed_message(map(), boolean() | nil) :: String.t()
  def delete_failed_message(%{retry: :queued}, true),
    do:
      dgettext(
        "dashboard_calendar_events",
        "Delete failed - queued to retry on next sync. Attendees have not been notified."
      )

  def delete_failed_message(%{retry: :queued}, _notify?),
    do: dgettext("dashboard_calendar_events", "Delete failed - queued to retry on next sync")

  def delete_failed_message(%{reason: :recurring_event}, _notify?),
    do: recurring_delete_refused_message()

  # The cached row does not say which occurrence or series the event is.
  def delete_failed_message(%{reason: reason}, _notify?)
      when reason in [:unaddressable_occurrence, :unaddressable_series] do
    dgettext(
      "dashboard_calendar_events",
      "This event could not be deleted here. Please delete it in your calendar app."
    )
  end

  def delete_failed_message(_failure, _notify?),
    do: dgettext("dashboard_calendar_events", "Failed to delete event")

  @doc "Changes dropped because a whole series was moved or written under them."
  @spec dropped_message(:series_move | :series_write, pos_integer()) :: String.t()
  def dropped_message(:series_move, count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was moved, but a change you made while it was moving was not applied. Please make it again.",
      "The series was moved, but %{count} changes you made while it was moving were not applied. Please make them again.",
      count
    )
  end

  def dropped_message(:series_write, count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was updated, but a change you made while it was saving was not applied. Please make it again.",
      "The series was updated, but %{count} changes you made while it was saving were not applied. Please make them again.",
      count
    )
  end

  @doc """
  The message shown when an event's repeat rule has no Outlook pattern
  (see `Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter`), so
  the event was not written.
  """
  @spec rule_not_supported_by_outlook_message() :: String.t()
  def rule_not_supported_by_outlook_message,
    do: dgettext("dashboard_calendar_events", "This repeat pattern can't be saved to Outlook.")

  @doc """
  The message shown when Outlook would move a repeating event onto the last
  day of the months that lack its day (`:day_missing_in_some_months`, see
  `Outlook.RecurrenceConverter`), so it was not written.
  """
  @spec month_end_refused_message() :: String.t()
  def month_end_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Outlook can't skip the months that don't have this series' day, and would move those events to the month's last day. Please start the series on the 28th or earlier, or save it to another calendar."
    )
  end

  @doc """
  Why a create failed, as the sentence that follows "Couldn't add …": the
  calendar's own refusal where it gave one the organiser can act on, else a
  plain request to try again.
  """
  @spec create_failure_reason(term()) :: String.t()
  def create_failure_reason(:rule_not_supported_by_outlook),
    do: rule_not_supported_by_outlook_message()

  def create_failure_reason(:day_missing_in_some_months), do: month_end_refused_message()
  def create_failure_reason(_reason), do: dgettext("dashboard_calendar", "Please try again.")

  @doc """
  Why a repeat rule was not written: a reason the calendar gives
  (`Tymeslot.CalendarGrid.RepeatRefusal`), or one the editor finds first.
  """
  @spec repeat_refusal(
          :day_missing_in_some_months
          | :rule_not_supported_by_outlook
          | :removal
          | :not_supported
          | :ends_before
          | :start_unknown
          | :until_before_start
        ) :: String.t()
  def repeat_refusal(:day_missing_in_some_months), do: month_end_refused_message()

  def repeat_refusal(:rule_not_supported_by_outlook),
    do: rule_not_supported_by_outlook_message()

  def repeat_refusal(:removal),
    do:
      dgettext(
        "dashboard_calendar_events",
        "That change cannot be made to the events you chose. A repeat rule can only be changed for all events, or this and following events, and cannot be removed here."
      )

  def repeat_refusal(:not_supported),
    do: dgettext("dashboard_calendar", "This calendar doesn't take repeat rules from Tymeslot.")

  def repeat_refusal(:ends_before),
    do:
      dgettext(
        "dashboard_calendar_repeat",
        "Not available: the new end comes before this event, so there are no following events to change."
      )

  def repeat_refusal(:start_unknown),
    do:
      dgettext(
        "dashboard_calendar_repeat",
        "This series' first event hasn't been read from your calendar yet, so the events left in it can't be counted. Refresh the calendar and try again."
      )

  def repeat_refusal(:until_before_start),
    do:
      dgettext(
        "dashboard_calendar_events",
        "The recurrence end date must be on or after the event start."
      )

  @doc """
  An organiser tried to move a repeating event whose provider cannot move a
  whole series (Exchange).
  """
  @spec recurring_move_refused_message() :: String.t()
  def recurring_move_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring events on this calendar cannot be moved to another calendar. Only single events can be moved."
    )
  end

  @doc "A change to an event refused because it is moving to another calendar."
  @spec moving_message() :: String.t()
  def moving_message do
    dgettext(
      "dashboard_calendar",
      "This event is moving to another calendar. Please make the change once it has moved."
    )
  end

  @doc "A move refused because another event's move has not answered yet."
  @spec another_moving_message() :: String.t()
  def another_moving_message,
    do: dgettext("dashboard_calendar", "Another event is moving. Try again in a moment.")

  @doc "An organiser has moved events too often in a short while."
  @spec move_rate_limited_message() :: String.t()
  def move_rate_limited_message,
    do: dgettext("dashboard_calendar_events", "Too many moves. Please wait a moment.")

  @doc """
  A write to a series refused because someone else organises it: moving or
  splitting a series re-creates it, which only its organiser may do.
  """
  @spec not_organiser_message() :: String.t()
  def not_organiser_message do
    dgettext(
      "dashboard_calendar_events",
      "Someone else organises this meeting, so Tymeslot can't move or split a series you were only invited to."
    )
  end

  @doc "The cached row could not be matched to the series it belongs to."
  @spec unmatched_series_message() :: String.t()
  def unmatched_series_message do
    dgettext(
      "dashboard_calendar_events",
      "This event could not be matched to its series. Refresh your calendars and try again."
    )
  end

  @doc """
  Why a series could not be moved, for each reason `Changes.move_event/3`
  and `Changes.series_move_notes/2` give. Every one means the series is
  still where it was.
  """
  @spec series_move_failed_message(term()) :: String.t()
  def series_move_failed_message(:recurring_event), do: recurring_move_refused_message()

  def series_move_failed_message(:cross_provider_series) do
    dgettext(
      "dashboard_calendar_events",
      "A recurring event can only be moved to a calendar of the same kind of account: Google to Google, Outlook to Outlook, or CalDAV to CalDAV."
    )
  end

  def series_move_failed_message(reason)
      when reason in [:unaddressable_series, :not_recurring, :unreadable_timing],
      do: unmatched_series_message()

  def series_move_failed_message(:not_organiser), do: not_organiser_message()

  def series_move_failed_message(:same_calendar),
    do: dgettext("dashboard_calendar_events", "The series is already on that calendar.")

  def series_move_failed_message(:no_destination_calendar) do
    dgettext(
      "dashboard_calendar_events",
      "That calendar cannot be written to. Please choose another calendar."
    )
  end

  def series_move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the series. It is still on its original calendar."
    )
  end

  @doc """
  What a single event's move to another calendar left behind, by the
  `:source` note `Changes.move_event/3` gave: `nil` for a clean move.
  """
  @spec moved_message(nil | :queued_delete | :left_behind | :unknown) ::
          {:info | :warning, String.t()}
  def moved_message(nil),
    do: {:info, dgettext("dashboard_calendar_events", "Event moved to the new calendar.")}

  def moved_message(:queued_delete) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar. The original will be removed on the next sync."
     )}
  end

  def moved_message(:left_behind) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the original could not be removed. Please delete it from its original calendar."
     )}
  end

  # Something failed once the new calendar had accepted the event, so it is
  # there, and whether the original is too cannot be said.
  def moved_message(:unknown) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "Event copied to the new calendar, but the move did not finish. Please check its original calendar and delete the original if it is still there."
     )}
  end

  @doc "What a whole series' move to `calendar` left behind, as `moved_message/1`."
  @spec series_moved_message(nil | :left_behind, String.t()) :: {:info | :warning, String.t()}
  def series_moved_message(:left_behind, calendar) do
    {:warning,
     dgettext(
       "dashboard_calendar_events",
       "The series was copied to %{calendar}, but the original series could not be removed. Please delete it from its original calendar.",
       calendar: calendar
     )}
  end

  def series_moved_message(_source, calendar) do
    {:info,
     dgettext("dashboard_calendar_events", "The series was moved to %{calendar}.",
       calendar: calendar
     )}
  end

  @doc "Why a single event's move to another calendar failed."
  @spec move_failed_message(term()) :: String.t()
  def move_failed_message(:recurring_event), do: recurring_move_refused_message()

  def move_failed_message(_reason) do
    dgettext(
      "dashboard_calendar_events",
      "Could not move the event. It is still on its original calendar."
    )
  end

  @doc "The video of a booking's calendar copy belongs to the booking."
  @spec booking_video_refused_message() :: String.t()
  def booking_video_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "This event is a booking, so its video link belongs to the booking. Reschedule or cancel the booking to change it."
    )
  end

  @doc "The message shown once an event's video room has been changed."
  @spec video_changed_message(String.t() | nil) :: String.t()
  def video_changed_message(nil),
    do: dgettext("dashboard_calendar_events", "Video link removed.")

  def video_changed_message(_url),
    do: dgettext("dashboard_calendar_events", "Video room created.")
end
