defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.NotifyPromptModal do
  @moduledoc "Confirmation modal asking whether attendees should be notified of a change or cancellation."

  use TymeslotWeb, :html

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
            No
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp header_text(:delete), do: "Send cancellation?"
  defp header_text(_update), do: "Notify attendees?"

  defp body_text(:delete, attendees) do
    "Send cancellation to #{length(attendees)} #{attendee_label(attendees)}?"
  end

  defp body_text(_update, attendees) do
    "Notify #{length(attendees)} #{attendee_label(attendees)} of this change?"
  end

  defp confirm_label(:delete), do: "Yes, send"
  defp confirm_label(_update), do: "Yes, notify"

  defp attendee_label([_one]), do: "attendee"
  defp attendee_label(_other), do: "attendees"
end
