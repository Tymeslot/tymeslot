defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.AvailabilitySection do
  @moduledoc """
  Stateless function component for the meeting-type form's availability
  section.

  Picks which of the profile's named availability schedules this meeting type
  is bookable against. The first option leaves the meeting type on the
  profile's default schedule, posted as a blank value and stored as `nil`, so
  renaming or re-pointing the default keeps applying without touching every
  meeting type.

  The select sits inside the surrounding meeting-type form (no nested form
  element), named so it serialises on the create submit; each change also
  dispatches `update_availability_schedule` back to the parent
  `MeetingTypeForm` (`@myself`), which owns the socket state and auto-save.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :schedules, :list, required: true
  attr :default_schedule_name, :string, required: true
  attr :selected_availability_schedule_id, :any, default: nil
  attr :myself, :any, required: true

  @spec availability_section(map()) :: Phoenix.LiveView.Rendered.t()
  def availability_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-calendar-days" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_form", "Availability")}
        </h3>
      </div>

      <div class="card-glass p-4 space-y-4">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_form",
            "Choose the hours this meeting type can be booked in. The default schedule applies unless you pick another one."
          )}
        </p>

        <.input
          type="select"
          name="meeting_type[availability_schedule_id]"
          label={dgettext("dashboard_meeting_form", "Schedule")}
          value={@selected_availability_schedule_id || ""}
          options={schedule_options(@schedules, @default_schedule_name)}
          phx-change="update_availability_schedule"
          phx-target={@myself}
        />
      </div>
    </section>
    """
  end

  defp schedule_options(schedules, default_schedule_name) do
    default_option =
      {dgettext("dashboard_meeting_form", "Default (%{name})", name: default_schedule_name), ""}

    [default_option | Enum.map(schedules, &{&1.name, &1.id})]
  end
end
