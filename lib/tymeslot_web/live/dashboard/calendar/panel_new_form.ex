defmodule TymeslotWeb.Dashboard.Calendar.PanelNewForm do
  @moduledoc """
  The side panel's "New event" form: the draft's fields in one form whose
  changes update the draft (`panel:draft_change`) and whose submit either
  adds a guest or creates the event (`panel:draft_submit`, by `intent`).
  The Create button names what it will do: "Create and invite" when the
  draft has guests, who are emailed once it is created.

  With a guest, the form offers to send the draft as a Tymeslot meeting
  (`PanelMeetingFields`, `PanelMeeting`). A meeting has times, is busy and
  has no place of its own, so All day, Show as and Place give way to the
  meeting's fields while it is ticked, and Notes becomes the note to the
  guests.

  Without guests, and on a plan with group bookings, it offers to make the
  draft a group event instead (`PanelGroupEventFields`, `PanelGroupEvent`).
  While that is ticked, the fields a sign-up event has no use for (All day,
  Show as, Place, Video, Guests) give way to its own, and Notes becomes the
  event's description.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Dashboard.Calendar.PanelCalendarField
  alias TymeslotWeb.Dashboard.Calendar.PanelGroupEvent
  alias TymeslotWeb.Dashboard.Calendar.PanelGroupEventFields
  alias TymeslotWeb.Dashboard.Calendar.PanelGuestsField
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelMeetingFields
  alias TymeslotWeb.Dashboard.Calendar.PanelVideoField

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :saving, :boolean, required: true
  attr :calendar_choices, :list, required: true
  attr :video_integrations, :list, required: true
  attr :guest_form_key, :integer, required: true
  attr :surface, :any, required: true
  attr :group_allowed, :boolean, default: false
  attr :venues, :list, default: []
  attr :timezone, :string, default: "Etc/UTC"

  @spec new_form(map()) :: Phoenix.LiveView.Rendered.t()
  def new_form(assigns) do
    group = PanelGroupEvent.on?(assigns.group_allowed, assigns.values)

    assigns =
      assign(assigns,
        shown_end: shown_end(assigns.values),
        meeting: PanelMeeting.on?(assigns.values) and not group,
        group: group,
        group_offered:
          assigns.calendar_choices != [] and
            PanelGroupEvent.offered?(assigns.group_allowed, assigns.values),
        timed: PanelMeeting.on?(assigns.values) or group
      )

    ~H"""
    <form
      novalidate
      id="calendar-panel-new-form"
      class="space-y-4"
      phx-change="panel:draft_change"
      phx-submit="panel:draft_submit"
      phx-target={@surface}
    >
      <.input
        id="calendar-panel-new-title"
        name="title"
        value={@values["title"]}
        label={dgettext("dashboard_calendar_editing", "Title")}
        placeholder={dgettext("dashboard_calendar_editing", "New event")}
        data-panel-focus="true"
      />
      <.input
        :if={!@timed}
        type="checkbox"
        id="calendar-panel-new-all-day"
        name="all_day"
        value={@values["all_day"]}
        label={dgettext("dashboard_calendar_editing", "All day")}
      />
      <%!-- A date and time does not fit half the panel's width: one per row. --%>
      <div
        id="calendar-panel-new-span"
        class={["grid gap-2", if(@values["all_day"], do: "grid-cols-2", else: "grid-cols-1")]}
      >
        <.date_picker
          :if={@values["all_day"]}
          id="calendar-panel-new-start"
          name="start"
          value={@values["start"]}
          label={dgettext("dashboard_calendar_editing", "Starts")}
        />
        <.datetime_picker
          :if={!@values["all_day"]}
          id="calendar-panel-new-start"
          name="start"
          value={@values["start"]}
          label={dgettext("dashboard_calendar_editing", "Starts")}
        />
        <.date_picker
          :if={@values["all_day"]}
          id="calendar-panel-new-end"
          name="end"
          value={@shown_end}
          label={dgettext("dashboard_calendar_editing", "Ends")}
        />
        <.datetime_picker
          :if={!@values["all_day"]}
          id="calendar-panel-new-end"
          name="end"
          value={@shown_end}
          label={dgettext("dashboard_calendar_editing", "Ends")}
        />
      </div>
      <PanelCalendarField.calendar_field choices={@calendar_choices} value={@values["calendar"]} />
      <div :if={!@meeting and !@group}>
        <.select
          id="calendar-panel-new-free"
          name="free"
          label={dgettext("dashboard_calendar_editing", "Show as")}
          value={to_string(@values["free"])}
          options={[
            {dgettext("dashboard_calendar_editing", "Busy"), "false"},
            {dgettext("dashboard_calendar_editing", "Free"), "true"}
          ]}
        />
        <p class="mt-1 text-token-xs text-tymeslot-500">
          {if @values["free"],
            do: dgettext("dashboard_calendar_editing", "Guests can book this time"),
            else: dgettext("dashboard_calendar_editing", "Guests can't book this time")}
        </p>
      </div>
      <.input
        :if={!@meeting and !@group}
        id="calendar-panel-new-location"
        name="location"
        value={@values["location"]}
        label={dgettext("dashboard_calendar_editing", "Place")}
      />
      <PanelVideoField.video_choice
        :if={!@group}
        video_integrations={@video_integrations}
        value={@values["video_integration_id"]}
      />
      <PanelGuestsField.draft_guests
        :if={!@group}
        guests={@values["guests"]}
        form_key={@guest_form_key}
        surface={@surface}
      />
      <PanelMeetingFields.meeting_fields :if={!@group} values={@values} />
      <PanelGroupEventFields.group_event_fields
        :if={@group_offered}
        values={@values}
        on={@group}
        venues={@venues}
        video_integrations={@video_integrations}
        timezone={@timezone}
      />
      <div>
        <.input
          type="textarea"
          id="calendar-panel-new-description"
          name="description"
          value={@values["description"]}
          label={notes_label(@meeting, @group)}
          placeholder={notes_placeholder(@meeting)}
          maxlength={@meeting && MeetingSchema.organizer_note_max_length()}
        />
        <p :if={@meeting} class="mt-1 text-token-xs text-tymeslot-500">
          {dgettext(
            "dashboard_calendar_events",
            "Included in the invitation and on the calendar entry."
          )}
        </p>
      </div>
      <div class="flex justify-end gap-2 border-t border-tymeslot-100 pt-3">
        <.action_button
          id="calendar-panel-new-cancel"
          type="button"
          variant={:secondary}
          phx-click="panel:draft_cancel"
          phx-target={@surface}
        >
          {dgettext("dashboard_calendar_editing", "Cancel")}
        </.action_button>
        <.action_button
          id="calendar-panel-create"
          type="submit"
          name="intent"
          value="create"
          variant={:primary}
          disabled={@saving}
        >
          {if @group or @values["guests"] == [],
            do: dgettext("dashboard_calendar_editing", "Create"),
            else: dgettext("dashboard_calendar_editing", "Create and invite")}
        </.action_button>
      </div>
    </form>
    """
  end

  defp notes_label(true, _group), do: dgettext("dashboard_calendar_events", "Note to the guest")

  defp notes_label(_meeting, true),
    do: dgettext("dashboard_group_events", "Description (optional)")

  defp notes_label(_meeting, _group), do: dgettext("dashboard_calendar_editing", "Notes")

  defp notes_placeholder(true),
    do: dgettext("dashboard_calendar_events", "An agenda, or anything to bring or prepare")

  defp notes_placeholder(false), do: nil

  # The all-day form shows the last day; the draft holds the exclusive end.
  defp shown_end(%{"all_day" => true, "end" => last}) when is_binary(last) do
    case Date.from_iso8601(last) do
      {:ok, date} -> date |> Date.add(-1) |> Date.to_iso8601()
      _invalid -> last
    end
  end

  defp shown_end(values), do: values["end"]
end
