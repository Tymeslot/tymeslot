defmodule TymeslotWeb.Components.Dashboard.Availability.ScheduleFormModal do
  @moduledoc """
  Modal component for naming a schedule, used both when creating a new one and
  when renaming an existing one.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the schedule name form modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `schedule_data` - Map containing the form `mode` (`:create` or `:rename`)
      and the `name` the input starts with (required)
    * `on_cancel` - JS command to execute when canceling (required)

  ## Examples

      <ScheduleFormModal.schedule_form_modal
        id="schedule-form-modal"
        show={@show_schedule_form_modal}
        schedule_data={@schedule_form_modal_data}
        on_cancel={JS.push("hide_schedule_form", target: @myself)}
        myself={@myself}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :schedule_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :myself, :any, required: true

  @spec schedule_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def schedule_form_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <CoreComponents.icon name="hero-calendar-days" class="w-5 h-5 text-turquoise-500" />
          {header_title(@schedule_data)}
        </div>
      </:header>

      <%= if @schedule_data do %>
        <form
          id="schedule-name-form"
          phx-submit="save_schedule"
          phx-target={@myself}
          class="space-y-2"
        >
          <label for="schedule-name-input" class="label">
            {dgettext("dashboard_availability", "Schedule name")}
          </label>
          <input
            type="text"
            id="schedule-name-input"
            name="name"
            value={@schedule_data.name}
            maxlength={AvailabilityScheduleSchema.name_max_length()}
            autocomplete="off"
            required
            phx-hook="AutoFocus"
            class="input"
            placeholder={dgettext("dashboard_availability", "For example: Consulting hours")}
          />
          <p class="text-token-sm text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_availability",
              "Each meeting type can be booked against one of your schedules."
            )}
          </p>
        </form>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:primary} type="submit" form="schedule-name-form">
            {dgettext("dashboard_availability", "Save")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  defp header_title(%{mode: :rename}), do: dgettext("dashboard_availability", "Rename schedule")
  defp header_title(_schedule_data), do: dgettext("dashboard_availability", "New schedule")
end
