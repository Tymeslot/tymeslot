defmodule TymeslotWeb.Dashboard.Calendar.PanelGroupEventFields do
  @moduledoc """
  The New event form's group-event fields (see `PanelGroupEvent`): the
  "Group event" box, and while it is ticked how many people can
  sign up, where the event takes place and when registration closes.

  A group event needs exactly one place fixed in advance, so the location is
  a single choice: one of the organiser's saved locations, or one of their
  video services. Drawn inside the form `PanelNewForm` draws, so a change
  reaches `panel:draft_change` like any other field. The box sits in a 44px
  row below 640px, where the panel is a sheet under a thumb.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :on, :boolean, required: true, doc: "`PanelGroupEvent.on?/2`"
  attr :venues, :list, required: true
  attr :video_integrations, :list, required: true
  attr :timezone, :string, required: true

  @spec group_event_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def group_event_fields(assigns) do
    ~H"""
    <section
      id="calendar-panel-group-event"
      class="space-y-3 rounded-token-lg border border-tymeslot-200 p-3"
    >
      <div
        id="calendar-panel-group-event-row"
        class="flex min-h-11 items-center sm:min-h-0 [&_label]:flex [&_label]:min-h-11 [&_label]:items-center sm:[&_label]:min-h-0"
      >
        <.input
          type="checkbox"
          id="calendar-panel-group-event-toggle"
          name="group_event"
          value={@values["group_event"]}
          label={dgettext("dashboard_group_events", "Group event")}
        />
      </div>
      <p class="text-token-xs text-tymeslot-500">
        {dgettext(
          "dashboard_group_events",
          "Creates a one-off event with its own booking link. People sign up until registration closes, and it is on your calendar at once."
        )}
      </p>
      <div :if={@on} id="calendar-panel-group-event-fields" class="space-y-3">
        <.input
          type="number"
          id="calendar-panel-group-event-max-participants"
          name="max_participants"
          label={dgettext("dashboard_group_events", "Participant limit")}
          value={@values["max_participants"]}
          min={Constraints.group_participants_range().first}
          max={Constraints.group_participants_range().last}
          step="1"
        />
        <div>
          <.select
            id="calendar-panel-group-event-location"
            name="group_location"
            label={dgettext("dashboard_group_events", "Location")}
            prompt={dgettext("dashboard_group_events", "Choose a location")}
            options={location_options(@venues, @video_integrations)}
            value={@values["group_location"]}
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
        <.datetime_picker
          id="calendar-panel-group-event-closes-at"
          name="closes_at"
          label={
            dgettext("dashboard_group_events", "Registration closes (optional, %{timezone})",
              timezone: @timezone
            )
          }
          value={@values["closes_at"]}
        />
      </div>
    </section>
    """
  end

  # Grouped as `options_for_select/2` takes them: one group per kind of place,
  # left out when the organiser has none of that kind.
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
