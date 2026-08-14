defmodule TymeslotWeb.Components.Dashboard.Availability.DeleteScheduleModal do
  @moduledoc """
  Modal component for confirming the deletion of an availability schedule.

  Meeting types booked against the schedule fall back to the default one, so the
  confirmation names them explicitly.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a delete schedule confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `schedule_data` - Map containing the schedule `name` and the
      `meeting_type_names` that currently use it (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)

  ## Examples

      <DeleteScheduleModal.delete_schedule_modal
        id="delete-schedule-modal"
        show={@show_delete_schedule_modal}
        schedule_data={@delete_schedule_modal_data}
        on_cancel={JS.push("hide_delete_schedule_modal", target: @myself)}
        on_confirm={JS.push("confirm_delete_schedule", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :schedule_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_schedule_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_schedule_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
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
          {dgettext("dashboard_availability", "Delete Schedule")}
        </div>
      </:header>

      <%= if @schedule_data do %>
        <div class="space-y-4">
          <%!-- phx-no-format: the HTML plugin collapses the trailing keyword
          argument onto the message line and the Elixir formatter splits it
          back out again, so the two never agree on this call. --%>
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed" phx-no-format>
            {dgettext(
              "dashboard_availability",
              "Are you sure you want to delete %{name}?",
              name: @schedule_data.name
            )}
          </p>

          <%= if @schedule_data.meeting_type_names == [] do %>
            <p class="text-tymeslot-500 font-medium">
              {dgettext(
                "dashboard_availability",
                "No meeting type uses this schedule. This action cannot be undone."
              )}
            </p>
          <% else %>
            <div class="space-y-2">
              <p class="text-tymeslot-500 font-medium">
                {dgettext(
                  "dashboard_availability",
                  "These meeting types will fall back to your default schedule:"
                )}
              </p>
              <ul class="list-disc list-inside text-tymeslot-600 font-medium">
                <li :for={meeting_type_name <- @schedule_data.meeting_type_names}>
                  {meeting_type_name}
                </li>
              </ul>
              <p class="text-tymeslot-500 font-medium">
                {dgettext("dashboard_availability", "This action cannot be undone.")}
              </p>
            </div>
          <% end %>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
            {dgettext("dashboard_availability", "Delete Schedule")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
