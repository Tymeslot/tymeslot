defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal do
  @moduledoc """
  Confirmation shown before an edit to one occurrence of a repeating event.

  The edit is written to the occurrence the organiser clicked (Google and
  Outlook address it by its own id), so the prompt offers that and nothing
  else. "This and following" and "All events" come back once a provider
  write honours a scope.
  """

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

      <p class="text-token-sm text-tymeslot-500 mb-4">
        {dgettext(
          "dashboard_calendar_events",
          "This event is part of a repeating series. Your change applies to this event only, and the rest of the series stays as it is. To change the whole series, use your calendar app."
        )}
      </p>

      <:footer>
        <.action_button
          variant={:secondary}
          phx-click={JS.push("cancel_recurrence_prompt", target: @myself)}
        >
          {dgettext("dashboard_calendar_events", "Cancel")}
        </.action_button>
        <.action_button
          phx-click="confirm_recurrence_scope"
          phx-value-scope="this_only"
          phx-target={@myself}
        >
          {dgettext("dashboard_calendar_events", "Update this event")}
        </.action_button>
      </:footer>
    </.modal>
    """
  end
end
