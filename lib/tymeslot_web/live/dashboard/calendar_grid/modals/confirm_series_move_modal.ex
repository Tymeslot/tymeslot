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
    <.modal
      id="confirm-series-move-modal"
      show={true}
      on_cancel={JS.push("cancel_series_move", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Move recurring event")}</:header>

      <p class="text-token-sm text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_events",
          "Move every event in this series to %{calendar}?",
          calendar: @prompt.calendar_name
        )}
      </p>

      <ul
        :if={@prompt.notes != []}
        id="series-move-notes"
        class="mt-4 space-y-2 list-disc pl-5 text-token-sm text-tymeslot-600"
      >
        <li :for={note <- @prompt.notes}>{SeriesNotes.text(note)}</li>
      </ul>

      <:footer>
        <div class="flex flex-wrap gap-2">
          <.action_button phx-click="confirm_series_move" phx-target={@myself}>
            {dgettext("dashboard_calendar_events", "Move series")}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("cancel_series_move", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
