defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.AvailabilitySection do
  @moduledoc """
  Stateless function component for the meeting-type form's availability
  section.

  Picks which of the profile's named availability schedules this meeting type
  is bookable against. The first chip leaves the meeting type on the profile's
  default schedule, held as `nil`, so renaming or re-pointing the default keeps
  applying without touching every meeting type.

  Chips rather than a select: a host owns at most a handful of schedules, and
  laying them out means the alternatives and the current choice are both visible
  without opening anything. Each carries the colour its schedule wears on the
  availability page, so "the amber one" is the same thing in both places.

  Clicking a chip dispatches `update_availability_schedule` to the parent
  `MeetingTypeForm` (`@myself`), which owns the socket state and auto-save; the
  create submit serialises the choice from the hidden field in `HiddenFields`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Availability.ScheduleAccents

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

        <div class="space-y-2">
          <span class="label" id="availability-schedule-label">
            {dgettext("dashboard_meeting_form", "Schedule")}
          </span>

          <div
            role="group"
            aria-labelledby="availability-schedule-label"
            class="flex flex-wrap items-center gap-3"
          >
            <.schedule_chip
              selected={is_nil(@selected_availability_schedule_id)}
              schedule_id=""
              myself={@myself}
              label={
                dgettext("dashboard_meeting_form", "Default (%{name})", name: @default_schedule_name)
              }
            />

            <.schedule_chip
              :for={{schedule, index} <- Enum.with_index(@schedules)}
              selected={@selected_availability_schedule_id == schedule.id}
              schedule_id={schedule.id}
              dot={ScheduleAccents.at(index).dot}
              myself={@myself}
              label={schedule.name}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :schedule_id, :any, required: true
  attr :selected, :boolean, required: true
  attr :dot, :string, default: nil
  attr :myself, :any, required: true

  # The param is named `schedule` rather than `value`, because LiveView's client
  # serialisation reads a button's native `value` property and would overwrite
  # `phx-value-value` with the empty string.
  defp schedule_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="update_availability_schedule"
      phx-value-schedule={@schedule_id}
      phx-target={@myself}
      aria-pressed={to_string(@selected)}
      class={[
        "btn-tag-selector btn-tag-selector-primary gap-2",
        @selected && "btn-tag-selector-primary--active"
      ]}
    >
      <span :if={@dot} class={["w-2.5 h-2.5 shrink-0 rounded-full", @dot]}></span>
      {@label}
    </button>
    """
  end
end
