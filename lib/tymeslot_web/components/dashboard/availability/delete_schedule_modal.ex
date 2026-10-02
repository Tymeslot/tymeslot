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
    <CoreComponents.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_availability", "Delete Schedule")}
      confirm_label={dgettext("dashboard_availability", "Delete Schedule")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <%= if @schedule_data do %>
        <%!-- phx-no-format: the HTML plugin collapses the trailing keyword
        argument onto the message line and the Elixir formatter splits it
        back out again, so the two never agree on this call. --%>
        <p phx-no-format>
          {dgettext(
            "dashboard_availability",
            "Are you sure you want to delete %{name}?",
            name: @schedule_data.name
          )}
        </p>

        <%= if @schedule_data.meeting_type_names == [] do %>
          <p class="text-tymeslot-500">
            {dgettext(
              "dashboard_availability",
              "No meeting type uses this schedule. This action cannot be undone."
            )}
          </p>
        <% else %>
          <div class="space-y-2">
            <p class="text-tymeslot-500">
              {dgettext(
                "dashboard_availability",
                "These meeting types will fall back to your default schedule:"
              )}
            </p>
            <ul class="list-disc list-inside">
              <li :for={meeting_type_name <- @schedule_data.meeting_type_names}>
                {meeting_type_name}
              </li>
            </ul>
            <p class="text-tymeslot-500">
              {dgettext("dashboard_availability", "This action cannot be undone.")}
            </p>
          </div>
        <% end %>
      <% end %>
    </CoreComponents.confirm_modal>
    """
  end
end
