defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.GroupEventFields do
  @moduledoc """
  The fields Quick Add asks for a one-off group event
  (`Tymeslot.MeetingTypes.OneOffEvents`), beside the title and time every
  mode has: how many people can sign up, where it takes place, when
  registration closes and what it is about.

  A group event needs exactly one place fixed in advance, so the location is
  a single choice: one of the host's saved locations, or one of their video
  services. The fields post as one form, `update_create_group_event`, and are
  only parsed and checked on save.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [input: 1]

  alias Tymeslot.Validation.Constraints

  attr :values, :map, required: true, doc: "the `:group_event` map of the form state"
  attr :venues, :list, default: []
  attr :video_integrations, :list, default: []
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  @spec group_event_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def group_event_fields(assigns) do
    ~H"""
    <form
      id="create-group-event-form"
      class="mb-3 space-y-3"
      phx-change="update_create_group_event"
      phx-target={@myself}
      onsubmit="return false;"
      data-testid="group-event-fields"
    >
      <p class="text-token-xs text-tymeslot-400">
        {dgettext(
          "dashboard_group_events",
          "Creates a one-off event with its own booking link. People sign up until registration closes, and it is on your calendar at once."
        )}
      </p>

      <div class="grid gap-3 sm:grid-cols-2">
        <.input
          type="number"
          id="create-group-event-max-participants"
          name="group_event[max_participants]"
          label={dgettext("dashboard_group_events", "Participant limit")}
          value={@values["max_participants"]}
          min={Constraints.group_participants_range().first}
          max={Constraints.group_participants_range().last}
          step="1"
          phx-debounce="300"
        />

        <div>
          <.input
            type="select"
            id="create-group-event-location"
            name="group_event[location]"
            label={dgettext("dashboard_group_events", "Location")}
            prompt={dgettext("dashboard_group_events", "Choose a location")}
            options={location_options(@venues, @video_integrations)}
            value={@values["location"]}
            data-testid="group-event-location"
          />
          <p
            :if={@venues == [] and @video_integrations == []}
            class="mt-1 text-token-xs text-tymeslot-500"
          >
            {dgettext(
              "dashboard_group_events",
              "Add a saved location or connect a video service to hold an event."
            )}
          </p>
        </div>
      </div>

      <.input
        type="datetime-local"
        id="create-group-event-closes-at"
        name="group_event[closes_at]"
        label={
          dgettext("dashboard_group_events", "Registration closes (optional, %{timezone})",
            timezone: @user_timezone
          )
        }
        value={@values["closes_at"]}
      />

      <.input
        type="textarea"
        id="create-group-event-description"
        name="group_event[description]"
        label={dgettext("dashboard_group_events", "Description (optional)")}
        value={@values["description"]}
        rows={3}
        phx-debounce="500"
      />
    </form>
    """
  end

  # Grouped as `options_for_select/2` takes them: one group per kind of place,
  # left out when the host has none of that kind.
  defp location_options(venues, video_integrations) do
    Enum.reject(
      [
        {dgettext("dashboard_group_events", "Saved locations"),
         Enum.map(venues, &{&1.name, "venue:#{&1.id}"})},
        {dgettext("dashboard_group_events", "Video call"),
         Enum.map(video_integrations, &{&1.name, "video:#{&1.id}"})}
      ],
      fn {_label, options} -> options == [] end
    )
  end
end
