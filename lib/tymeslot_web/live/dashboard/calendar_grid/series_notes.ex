defmodule TymeslotWeb.Dashboard.CalendarGrid.SeriesNotes do
  @moduledoc """
  The wording of what a write to a recurring series will not carry, which
  the organiser reads before confirming it: the notes of a move to another
  calendar (`Tymeslot.CalendarGrid.SeriesTransfer.note/0`), shown by
  `Modals.ConfirmSeriesMoveModal`, and of an edit of this and every
  following event (`Tymeslot.CalendarGrid.SeriesEdit.following_note/0`),
  shown by `Modals.RecurrencePromptModal`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "What the organiser is told for `note`."
  @spec text(atom()) :: String.t()
  def text(:changed_occurrences_reset) do
    dgettext(
      "dashboard_calendar_events",
      "Events in the series that were changed on their own go back to the series' usual pattern."
    )
  end

  def text(:changed_or_cancelled_occurrences_reset) do
    dgettext(
      "dashboard_calendar_events",
      "Events in the series that were changed or cancelled on their own go back to the series' usual pattern."
    )
  end

  def text(:teams_meeting_not_carried) do
    dgettext(
      "dashboard_calendar_events",
      "A Teams meeting on the series is not carried over."
    )
  end

  def text(:guests_reinvited) do
    dgettext(
      "dashboard_calendar_events",
      "Guests are sent a cancellation for the original series and an invitation to the moved one."
    )
  end

  def text(:unmatched_changes_reset) do
    dgettext(
      "dashboard_calendar_events",
      "Later events that were changed or cancelled on their own keep that only on dates the new pattern still includes."
    )
  end
end
