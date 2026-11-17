defmodule TymeslotWeb.Dashboard.Calendar.PanelMeetingFields do
  @moduledoc """
  The New event form's meeting fields (see `PanelMeeting`): the "Send as a
  Tymeslot meeting" box, offered once the draft has a guest, and while it
  is ticked the guest's name, the language of every email about the
  meeting and its reminder emails, chosen with the reminder picker the
  meeting type form uses (`PanelMeetingReminders`), its common lead times
  a click away. Drawn inside the form `PanelNewForm`
  draws, so a change reaches `panel:draft_change` like any other field.
  Each box and the toggle sit in a 44px row below 640px, where the panel is
  a sheet under a thumb, and their labels fill the row so the whole row taps.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias TymeslotWeb.Components.Shared.ReminderPicker
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelMeetingReminders

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :reminder_picker, :map, default: nil, doc: "the panel's `ReminderPickerState`"
  attr :surface, :any, required: true

  # The lead times a click away: the ones the panel offered before any
  # could be typed.
  @reminder_presets [
    %{value: 30, unit: "minutes"},
    %{value: 1, unit: "hours"},
    %{value: 1, unit: "days"}
  ]

  @spec meeting_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_fields(assigns) do
    assigns =
      assign(assigns,
        on: PanelMeeting.on?(assigns.values),
        reminder_picker: assigns.reminder_picker || PanelMeetingReminders.new(),
        reminder_presets: @reminder_presets
      )

    ~H"""
    <section
      :if={@values["guests"] != []}
      id="calendar-panel-meeting"
      class="space-y-3 rounded-token-lg border border-tymeslot-200 p-3"
    >
      <div
        id="calendar-panel-meeting-row"
        class="flex min-h-11 items-center sm:min-h-0 [&_label]:flex [&_label]:min-h-11 [&_label]:items-center sm:[&_label]:min-h-0"
      >
        <.input
          type="checkbox"
          id="calendar-panel-meeting-toggle"
          name="meeting"
          value={@values["meeting"]}
          label={dgettext("dashboard_calendar_power", "Send as a Tymeslot meeting")}
        />
      </div>
      <p class="text-token-xs text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_events",
          "Books the slot, emails the guest an invitation, and adds it to your calendar."
        )}
      </p>
      <div :if={@on} id="calendar-panel-meeting-fields" class="space-y-3">
        <.input
          id="calendar-panel-meeting-guest-name"
          name="guest_name"
          maxlength="255"
          value={@values["guest_name"]}
          label={dgettext("dashboard_calendar_events", "Guest name")}
          placeholder={dgettext("dashboard_calendar_events", "Ada Lovelace")}
        />
        <div>
          <.select
            id="calendar-panel-meeting-locale"
            name="locale"
            value={@values["locale"]}
            label={dgettext("dashboard_calendar_events", "Language of the invitation")}
            options={Enum.map(Locales.supported(), &{&1.name, &1.code})}
          />
          <p class="mt-1 text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_events",
              "The language every email about this meeting is written in, for the guest and anyone else invited."
            )}
          </p>
        </div>
        <div id="calendar-panel-meeting-reminders">
          <ReminderPicker.reminder_picker
            reminders={@reminder_picker.reminders}
            max_reminders={ReminderValidation.max_reminders()}
            new_reminder_value={@reminder_picker.new_reminder_value}
            new_reminder_unit={@reminder_picker.new_reminder_unit}
            reminder_error={@reminder_picker.reminder_error}
            show_custom_reminder={@reminder_picker.show_custom_reminder}
            reminder_confirmation={@reminder_picker.reminder_confirmation}
            description={
              dngettext(
                "dashboard_calendar_events",
                "Add up to %{count} reminder email for this meeting. The guest and anyone else invited receive it.",
                "Add up to %{count} reminder emails for this meeting. The guest and anyone else invited receive it.",
                ReminderValidation.max_reminders()
              )
            }
            presets={@reminder_presets}
            event_prefix="panel:meeting_"
            myself={@surface}
          />
        </div>
      </div>
    </section>
    """
  end
end
