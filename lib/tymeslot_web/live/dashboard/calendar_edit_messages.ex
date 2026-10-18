defmodule TymeslotWeb.Dashboard.CalendarEditMessages do
  @moduledoc """
  What both calendar surfaces tell the organiser when a change is refused
  (`Tymeslot.CalendarGrid.EditGuard`), when a delete or a create fails, and when
  changes made while a whole series was saving were dropped. One copy, so
  the two calendars can never word the same refusal differently.
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
end
