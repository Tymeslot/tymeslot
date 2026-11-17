defmodule TymeslotWeb.Dashboard.Calendar.SeriesMoveModal do
  @moduledoc """
  Asks the organiser to confirm moving a whole repeating series to another
  calendar, which is what choosing another calendar for one of its events
  does, and says what the move will not carry (`Changes.series_move_notes/2`).
  Move sends `panel:confirm_series_move`; Cancel, Escape and a click outside
  send `panel:cancel_series_move`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Calendar.SeriesNotes
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :prompt, :map, required: true, doc: "`%{title, destination: %{name}, notes}`"
  attr :target, :any, required: true

  @spec series_move_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def series_move_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id="calendar-series-move"
      show
      size={:small}
      icon="hero-arrow-path"
      confirm_variant={:primary}
      title={dgettext("dashboard_calendar_editing", "Move a repeating event")}
      on_cancel={JS.push("panel:cancel_series_move", target: @target)}
    >
      <p>
        {dgettext("dashboard_calendar_editing", "Move every event in this series to %{calendar}?",
          calendar: @prompt.destination.name
        )}
      </p>
      <ul
        :if={@prompt.notes != []}
        id="calendar-series-move-notes"
        class="list-disc space-y-2 pl-5 text-token-sm"
      >
        <li :for={note <- @prompt.notes}>{SeriesNotes.text(note)}</li>
      </ul>
      <p class="text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "Moving a series can't be undone here.")}
      </p>
      <:actions>
        <.action_button
          id="calendar-series-move-cancel"
          variant={:secondary}
          phx-click="panel:cancel_series_move"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Cancel")}
        </.action_button>
        <.action_button
          id="calendar-series-move-confirm"
          variant={:primary}
          phx-click="panel:confirm_series_move"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar_editing", "Move series")}
        </.action_button>
      </:actions>
    </Modal.confirm_modal>
    """
  end
end
