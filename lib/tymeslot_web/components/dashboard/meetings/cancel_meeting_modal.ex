defmodule TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal do
  @moduledoc """
  Modal component for confirming meeting cancellation.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Dashboard.Meetings.Helpers

  @doc """
  Renders a cancel meeting confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `meeting` - The meeting to be cancelled (required)
    * `timezone` - The timezone to display times in (optional, defaults to UTC)
    * `cancelling` - Boolean indicating if cancellation is in progress (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming cancellation (required)

  ## Examples

      <CancelMeetingModal.cancel_meeting_modal
        id="cancel-meeting-modal"
        show={@show_cancel_meeting_modal}
        meeting={@cancel_meeting_modal_data}
        cancelling={@cancelling_meeting == @cancel_meeting_modal_data.id}
        on_cancel={JS.push("hide_cancel_modal", target: @myself)}
        on_confirm={JS.push("confirm_cancel_meeting", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :cancelling, :boolean, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec cancel_meeting_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_meeting_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel}>
      <:header>
        <div class="flex items-center gap-2">
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          Cancel Meeting
        </div>
      </:header>

      <%= if @meeting do %>
        <p class="text-gray-700">
          Are you sure you want to cancel the meeting with <strong>{@meeting.attendee_name}</strong>
          scheduled for <strong><%= Helpers.format_meeting_date(@meeting, @timezone) %> • <%= Helpers.format_meeting_time(@meeting, @timezone) %></strong>?
        </p>
        <p class="mt-2 text-sm text-gray-600">
          This action cannot be undone. The attendee will be notified of the cancellation.
        </p>
      <% end %>

      <:footer>
        <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
          Keep Meeting
        </CoreComponents.action_button>
        <CoreComponents.loading_button
          variant={:danger}
          phx-click={@on_confirm}
          loading={@cancelling}
          loading_text="Cancelling..."
        >
          Cancel Meeting
        </CoreComponents.loading_button>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
