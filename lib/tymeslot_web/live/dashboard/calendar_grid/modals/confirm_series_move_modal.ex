defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmSeriesMoveModal do
  @moduledoc """
  Asks the organiser to confirm moving a whole recurring series to another
  calendar, which is what choosing another calendar for one of its events
  does, and says what the move will not carry to that calendar.

  `prompt` is the one `EventHandlers.SeriesMove.prompt/4` builds: the
  destination calendar's name and the notes
  `Tymeslot.CalendarGrid.series_move_notes/2` gave for it. Confirming sends
  `confirm_series_move`, cancelling `cancel_series_move`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.CalendarGrid.SeriesNotes

  attr :prompt, :map, required: true
  attr :myself, :any, required: true

  @spec confirm_series_move_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_series_move_modal(assigns) do
    ~H"""
    <.confirm_modal
      id="confirm-series-move-modal"
      show
      size={:small}
      title={dgettext("dashboard_calendar_events", "Move recurring event")}
      confirm_label={dgettext("dashboard_calendar_events", "Move series")}
      confirm_variant={:primary}
      icon="hero-arrow-path"
      on_cancel={JS.push("cancel_series_move", target: @myself)}
      on_confirm={JS.push("confirm_series_move", target: @myself)}
    >
      <p>
        {dgettext(
          "dashboard_calendar_events",
          "Move every event in this series to %{calendar}?",
          calendar: @prompt.calendar_name
        )}
      </p>

      <ul
        :if={@prompt.notes != []}
        id="series-move-notes"
        class="space-y-2 list-disc pl-5 text-token-sm"
      >
        <li :for={note <- @prompt.notes}>{SeriesNotes.text(note)}</li>
      </ul>
    </.confirm_modal>
    """
  end
end
