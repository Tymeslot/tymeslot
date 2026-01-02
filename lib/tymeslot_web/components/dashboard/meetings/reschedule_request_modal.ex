defmodule TymeslotWeb.Components.Dashboard.Meetings.RescheduleRequestModal do
  @moduledoc """
  Modal component for sending reschedule requests to meeting attendees.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a reschedule request confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `meeting` - The meeting to be rescheduled (required)
    * `timezone` - The timezone to display times in (optional, defaults to UTC)
    * `sending` - Boolean indicating if request is being sent (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming (required)

  ## Examples

      <RescheduleRequestModal.reschedule_request_modal
        id="reschedule-modal"
        show={@show_reschedule_request_modal}
        meeting={@reschedule_request_modal_data}
        sending={@sending_reschedule == @reschedule_request_modal_data.id}
        on_cancel={JS.push("hide_reschedule_modal", target: @myself)}
        on_confirm={JS.push("confirm_reschedule_request", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :sending, :boolean, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec reschedule_request_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def reschedule_request_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel}>
      <:header>
        <div class="flex items-center gap-2">
          <svg
            class="w-5 h-5 text-turquoise-600"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
            />
          </svg>
          Send Reschedule Request
        </div>
      </:header>

      <%= if @meeting do %>
        <div class="space-y-4">
          <p class="text-neutral-700">
            Send a reschedule request to <strong class="font-semibold text-neutral-800">{@meeting.attendee_name}</strong>?
          </p>

          <div class="bg-neutral-50 rounded-lg p-4 space-y-2">
            <p class="text-sm font-medium text-neutral-700">Current Meeting:</p>
            <div class="text-sm text-neutral-600 space-y-1">
              <div class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-turquoise-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                  />
                </svg>
                <span>{format_meeting_datetime(@meeting, @timezone)}</span>
              </div>
              <div class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-turquoise-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <span>{@meeting.duration} minutes</span>
              </div>
            </div>
          </div>

          <div class="bg-turquoise-50 border border-turquoise-200 rounded-lg p-4">
            <p class="text-sm text-turquoise-800">
              <strong class="font-medium">What happens next:</strong>
            </p>
            <ul class="mt-2 text-sm text-turquoise-700 space-y-1 list-disc list-inside">
              <li>The current meeting will be cancelled immediately</li>
              <li>
                {@meeting.attendee_name} will receive an email explaining you need to reschedule
              </li>
              <li>They can choose a new time from your availability</li>
              <li>You'll both receive confirmation once they select a new time</li>
            </ul>
          </div>
        </div>
      <% end %>

      <:footer>
        <button type="button" phx-click={@on_cancel} class="btn btn-secondary">
          Cancel
        </button>
        <button type="button" phx-click={@on_confirm} disabled={@sending} class="btn btn-primary">
          <%= if @sending do %>
            <svg class="animate-spin h-4 w-4 mr-1.5" fill="none" viewBox="0 0 24 24">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              >
              </path>
            </svg>
            Sending...
          <% else %>
            Send Request
          <% end %>
        </button>
      </:footer>
    </CoreComponents.modal>
    """
  end

  # Private helper functions

  defp format_meeting_datetime(meeting, timezone) do
    # Convert UTC times to the appropriate timezone
    local_start = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    local_end = DateTimeUtils.convert_to_timezone(meeting.end_time, timezone)

    date = Calendar.strftime(local_start, "%B %d, %Y")
    start_time = Calendar.strftime(local_start, "%-I:%M %p")
    end_time = Calendar.strftime(local_end, "%-I:%M %p")
    "#{date} • #{start_time} - #{end_time}"
  end
end
