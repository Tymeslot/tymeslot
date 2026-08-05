defmodule TymeslotWeb.Components.Dashboard.Meetings.RescheduleRequestModal do
  @moduledoc """
  Modal component for sending reschedule requests to meeting attendees.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

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
  attr :time_format, :string, default: "24h"
  attr :sending, :boolean, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec reschedule_request_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def reschedule_request_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
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
              stroke-width="2.5"
              d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
            />
          </svg>
          {dgettext("dashboard_bookings", "Send Reschedule Request")}
        </div>
      </:header>

      <%= if @meeting do %>
        <div class="space-y-6">
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
            {dgettext("dashboard_bookings", "Send a reschedule request to %{name}?",
              name: @meeting.attendee_name
            )}
          </p>

          <div class="bg-tymeslot-50 rounded-token-2xl p-6 border border-tymeslot-100 space-y-3">
            <p class="text-token-xs font-black text-tymeslot-500 uppercase tracking-wider">
              {dgettext("dashboard_bookings", "Current Meeting")}
            </p>
            <div class="text-tymeslot-900 font-black text-lg space-y-2">
              <div class="flex items-center gap-3">
                <CoreComponents.icon name="hero-calendar" class="w-5 h-5 text-turquoise-600" />
                <span>{Helpers.format_meeting_date(@meeting, @timezone)} • {Helpers.format_meeting_time(@meeting, @timezone, @time_format)}</span>
              </div>
              <div class="flex items-center gap-3">
                <CoreComponents.icon name="hero-clock" class="w-5 h-5 text-turquoise-600" />
                <span>
                  {dngettext(
                    "dashboard_bookings",
                    "%{duration} minute",
                    "%{duration} minutes",
                    @meeting.duration,
                    duration: @meeting.duration
                  )}
                </span>
              </div>
            </div>
          </div>

          <div class="bg-turquoise-50/50 border-2 border-turquoise-100 rounded-token-2xl p-6">
            <p class="text-turquoise-800 font-black mb-3">
              {dgettext("dashboard_bookings", "What happens next:")}
            </p>
            <ul class="text-turquoise-700 font-medium space-y-2">
              <li class="flex items-start gap-2">
                <span class="mt-1.5 w-1.5 h-1.5 rounded-full bg-turquoise-400 shrink-0"></span>
                <span>{dgettext("dashboard_bookings", "The current meeting will be cancelled immediately")}</span>
              </li>
              <li class="flex items-start gap-2">
                <span class="mt-1.5 w-1.5 h-1.5 rounded-full bg-turquoise-400 shrink-0"></span>
                <span>{dgettext(
                  "dashboard_bookings",
                  "%{attendee_name} will receive an email explaining you need to reschedule",
                  attendee_name: @meeting.attendee_name
                )}</span>
              </li>
              <li class="flex items-start gap-2">
                <span class="mt-1.5 w-1.5 h-1.5 rounded-full bg-turquoise-400 shrink-0"></span>
                <span>{dgettext("dashboard_bookings", "They can choose a new time from your availability")}</span>
              </li>
              <li class="flex items-start gap-2">
                <span class="mt-1.5 w-1.5 h-1.5 rounded-full bg-turquoise-400 shrink-0"></span>
                <span>{dgettext(
                  "dashboard_bookings",
                  "You'll both receive confirmation once they select a new time"
                )}</span>
              </li>
            </ul>
          </div>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_bookings", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.loading_button
            variant={:primary}
            phx-click={@on_confirm}
            loading={@sending}
            loading_text={dgettext("dashboard_bookings", "Sending...")}
          >
            {dgettext("dashboard_bookings", "Send Request")}
          </CoreComponents.loading_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  # Private helper functions
end
