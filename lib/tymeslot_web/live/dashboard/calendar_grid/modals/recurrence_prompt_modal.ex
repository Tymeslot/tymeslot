defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal do
  @moduledoc "Recurrence scope selection modal for editing recurring calendar events."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :recurrence_prompt, :map, required: true
  attr :myself, :any, required: true

  @spec recurrence_prompt_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def recurrence_prompt_modal(assigns) do
    ~H"""
    <.modal
      id="recurrence-prompt-modal"
      show={true}
      on_cancel={JS.push("cancel_recurrence_prompt", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Edit recurring event")}</:header>

      <p class="text-token-sm text-tymeslot-500 mb-4">{dgettext("dashboard_calendar_events", "Which events do you want to update?")}</p>

      <div class="flex flex-col gap-2 mb-4">
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="this_only"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          {dgettext("dashboard_calendar_events", "This event only")}
        </button>
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="this_and_following"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          {dgettext("dashboard_calendar_events", "This and following events")}
        </button>
        <button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="all"
          phx-target={@myself}
          class="w-full text-left px-4 py-2.5 rounded-lg border border-tymeslot-200 hover:bg-tymeslot-50 text-token-sm text-tymeslot-700"
        >
          {dgettext("dashboard_calendar_events", "All events in series")}
        </button>
      </div>

      <:footer>
        <.action_button
          variant={:secondary}
          phx-click={JS.push("cancel_recurrence_prompt", target: @myself)}
        >
          {dgettext("dashboard_calendar_events", "Cancel")}
        </.action_button>
      </:footer>
    </.modal>
    """
  end
end
