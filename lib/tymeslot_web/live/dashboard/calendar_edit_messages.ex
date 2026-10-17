defmodule TymeslotWeb.Dashboard.CalendarEditMessages do
  @moduledoc """
  What both calendar surfaces tell the organiser when a change is refused
  (`Tymeslot.CalendarGrid.EditGuard`), when a delete fails, and when
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
end
