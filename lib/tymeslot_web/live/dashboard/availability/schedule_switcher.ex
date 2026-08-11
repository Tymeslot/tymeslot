defmodule TymeslotWeb.Dashboard.Availability.ScheduleSwitcher do
  @moduledoc """
  Schedule picker and management actions for the availability page.

  A profile owns several named schedules, exactly one of which is the default.
  This switcher chooses which one the page below it is editing and exposes the
  actions that change the set itself: create, rename, duplicate, promote to
  default, and delete.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders the schedule select and its management actions.
  """
  attr :schedules, :list, required: true
  attr :selected_schedule, :map, default: nil
  attr :myself, :any, required: true

  @spec schedule_switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def schedule_switcher(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <div class="flex flex-col lg:flex-row lg:items-end gap-6">
        <div class="lg:w-80">
          <form id="schedule-switcher-form" phx-change="select_schedule" phx-target={@myself}>
            <.input
              type="select"
              name="schedule_id"
              label={dgettext("dashboard_availability", "Schedule")}
              value={@selected_schedule && @selected_schedule.id}
              options={schedule_options(@schedules)}
            />
          </form>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.action_button
            variant={:primary}
            phx-click="show_schedule_form"
            phx-value-mode="create"
            phx-target={@myself}
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_availability", "New schedule")}
          </.action_button>

          <.action_button
            :if={@selected_schedule}
            variant={:secondary}
            phx-click="show_schedule_form"
            phx-value-mode="rename"
            phx-target={@myself}
          >
            {dgettext("dashboard_availability", "Rename")}
          </.action_button>

          <.action_button
            :if={@selected_schedule}
            variant={:secondary}
            phx-click="duplicate_schedule"
            phx-target={@myself}
          >
            {dgettext("dashboard_availability", "Duplicate")}
          </.action_button>

          <.action_button
            :if={@selected_schedule && not @selected_schedule.is_default}
            variant={:secondary}
            phx-click="set_default_schedule"
            phx-target={@myself}
          >
            {dgettext("dashboard_availability", "Make default")}
          </.action_button>

          <.action_button
            :if={@selected_schedule && not @selected_schedule.is_default}
            variant={:danger}
            phx-click="show_delete_schedule_modal"
            phx-target={@myself}
          >
            {dgettext("dashboard_availability", "Delete")}
          </.action_button>
        </div>
      </div>
    </div>
    """
  end

  defp schedule_options(schedules) do
    Enum.map(schedules, fn schedule -> {option_label(schedule), schedule.id} end)
  end

  defp option_label(%{is_default: true, name: name}),
    do: dgettext("dashboard_availability", "%{name} (default)", name: name)

  defp option_label(%{name: name}), do: name
end
