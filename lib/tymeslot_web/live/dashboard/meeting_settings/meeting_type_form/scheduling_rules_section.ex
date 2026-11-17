defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SchedulingRulesSection do
  @moduledoc """
  Stateless function component for the meeting-type form's scheduling rules:
  both buffers, the minimum notice and the booking window.

  The availability schedule sets these, and one schedule usually serves several
  meeting types. Each field here overrides the schedule's rule for this meeting
  type alone; an empty field keeps the schedule's, which the hint under it
  names, so a later change on the availability page still reaches this type.

  The inherited values come from the schedule picked in the availability
  section just above, so switching schedules updates the hints at once.

  The inputs are part of the surrounding meeting-type form (no nested form
  element); each change dispatches `update_scheduling_rules` back to the parent
  `MeetingTypeForm` (`@myself`), which owns the socket state and auto-save.

  While the type offers a series (`series`), the booking window bounds its
  first session only, and a note beside the field says so.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @id "meeting-type-scheduling-rules"

  attr :scheduling_rules, :map, required: true, doc: "Form values keyed by field name"
  attr :schedules, :list, required: true
  attr :selected_availability_schedule_id, :any, default: nil
  attr :form_errors, :map, default: %{}

  attr :series, :boolean,
    default: false,
    doc: "Whether the type offers a series (one paused by the plan does not)"

  attr :myself, :any, required: true

  @spec scheduling_rules_section(map()) :: Phoenix.LiveView.Rendered.t()
  def scheduling_rules_section(assigns) do
    schedule = inherited_schedule(assigns.schedules, assigns.selected_availability_schedule_id)

    assigns =
      assign(assigns,
        id: @id,
        fields:
          Enum.map(Constraints.scheduling_policy_fields(), fn field ->
            %{
              field: field,
              label: label(field),
              value: Map.get(assigns.scheduling_rules, Atom.to_string(field)),
              inherited:
                dgettext("dashboard_meeting_form", "Schedule: %{value}",
                  value: Schedules.policy(schedule, field)
                ),
              range: range(field),
              errors: field_errors(assigns.form_errors, field),
              series_note?: assigns.series and field == :advance_booking_days
            }
          end)
      )

    ~H"""
    <section class="space-y-4">
      <.subsection_header
        id={"#{@id}-heading"}
        icon="hero-clock"
        title={dgettext("dashboard_meeting_form", "Scheduling rules")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Buffers and notice come from the schedule above. Enter a value to use a different one for this meeting type, or leave a field empty to keep the schedule's."
          )
        }
      />

      <.card variant={:flat} padding={:sm}>
        <div
          role="group"
          aria-labelledby={"#{@id}-heading"}
          class="grid grid-cols-1 gap-4 sm:grid-cols-2"
        >
          <div :for={f <- @fields} class="space-y-1">
            <label for={"#{@id}-#{f.field}"} class="block text-token-sm font-medium text-tymeslot-700">
              {f.label}
            </label>
            <.input
              type="number"
              id={"#{@id}-#{f.field}"}
              name={"meeting_type[#{f.field}]"}
              value={f.value}
              min={f.range.first}
              max={f.range.last}
              step="1"
              placeholder={dgettext("dashboard_meeting_form", "Use schedule")}
              aria-describedby={"#{@id}-#{f.field}-hint"}
              phx-change="update_scheduling_rules"
              phx-debounce="500"
              phx-target={@myself}
            />
            <p id={"#{@id}-#{f.field}-hint"} class="text-token-xs text-tymeslot-500">
              {f.inherited}
            </p>
            <p
              :if={f.series_note?}
              class="text-token-xs text-tymeslot-600"
              data-testid="booking-window-series-note"
            >
              {dgettext(
                "dashboard_booking_series",
                "With series booking on, this applies to the first session only."
              )}
            </p>
            <p :for={error <- f.errors} class="text-token-sm text-red-600">{error}</p>
          </div>
        </div>
      </.card>
    </section>
    """
  end

  @doc """
  How many days ahead the type's first session may be booked: its own booking
  window when it sets one, the schedule's otherwise.
  """
  @spec booking_window_days(map(), list(), integer() | nil) :: pos_integer()
  def booking_window_days(scheduling_rules, schedules, selected_availability_schedule_id) do
    case Integer.parse(Map.get(scheduling_rules, "advance_booking_days") || "") do
      {days, ""} when days > 0 ->
        days

      _schedule_window ->
        schedules
        |> inherited_schedule(selected_availability_schedule_id)
        |> Schedules.policy(:advance_booking_days)
    end
  end

  # The schedule this meeting type is booked against: the one picked, or the
  # profile's default while "Default" is selected. Nil before the profile has
  # any, which `Schedules.policy/2` answers with the application defaults.
  defp inherited_schedule(schedules, nil), do: Enum.find(schedules, & &1.is_default)
  defp inherited_schedule(schedules, id), do: Enum.find(schedules, &(&1.id == id))

  defp label(:buffer_before_minutes),
    do: dgettext("dashboard_meeting_form", "Buffer before (minutes)")

  defp label(:buffer_after_minutes),
    do: dgettext("dashboard_meeting_form", "Buffer after (minutes)")

  defp label(:min_advance_hours), do: dgettext("dashboard_meeting_form", "Minimum notice (hours)")

  defp label(:advance_booking_days),
    do: dgettext("dashboard_meeting_form", "Booking window (days)")

  defp range(field) when field in [:buffer_before_minutes, :buffer_after_minutes],
    do: Constraints.buffer_minutes_range()

  defp range(:min_advance_hours), do: Constraints.min_advance_hours_range()
  defp range(:advance_booking_days), do: Constraints.advance_booking_days_range()

  defp field_errors(form_errors, field) do
    form_errors
    |> FormValidationHelpers.field_errors(field)
    |> Enum.map(&Helpers.format_errors/1)
  end
end
