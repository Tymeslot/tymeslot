defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.NotifyPromptModal do
  @moduledoc "Confirmation modal asking whether attendees should be notified of a change or cancellation."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :notify_prompt, :map, required: true
  attr :kind, :atom, default: :update
  attr :myself, :any, required: true

  @spec notify_prompt_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def notify_prompt_modal(assigns) do
    ~H"""
    <.modal
      id="notify-prompt-modal"
      show={true}
      on_cancel={JS.push("notify_prompt_cancel", target: @myself)}
      size={:small}
    >
      <:header>{header_text(@kind)}</:header>

      <p class="text-token-sm text-tymeslot-500">
        {body_text(@kind, @notify_prompt.attendees)}
      </p>

      <:footer>
        <div class="flex gap-2">
          <.action_button
            variant={:primary}
            phx-click="notify_prompt_confirm"
            phx-target={@myself}
          >
            {confirm_label(@kind)}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("notify_prompt_cancel", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "No")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp header_text(:delete), do: dgettext("dashboard_calendar_events", "Send cancellation?")
  defp header_text(_update), do: dgettext("dashboard_calendar_events", "Notify attendees?")

  defp body_text(:delete, attendees) do
    dngettext(
      "dashboard_calendar_events",
      "Send cancellation to %{count} attendee?",
      "Send cancellation to %{count} attendees?",
      length(attendees)
    )
  end

  defp body_text(_update, attendees) do
    dngettext(
      "dashboard_calendar_events",
      "Notify %{count} attendee of this change?",
      "Notify %{count} attendees of this change?",
      length(attendees)
    )
  end

  defp confirm_label(:delete), do: dgettext("dashboard_calendar_events", "Yes, send")
  defp confirm_label(_update), do: dgettext("dashboard_calendar_events", "Yes, notify")
end
