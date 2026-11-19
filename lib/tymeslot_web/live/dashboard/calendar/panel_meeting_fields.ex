defmodule TymeslotWeb.Dashboard.Calendar.PanelMeetingFields do
  @moduledoc """
  The New event form's meeting fields (see `PanelMeeting`): the "Send as a
  Tymeslot meeting" box, offered once the draft has a guest, and while it
  is ticked whether the first guest is the meeting's main participant, the
  guest's name (with one), the meeting's place, the language of every
  email about the meeting and its reminder emails, chosen with the reminder
  picker the meeting type form uses (`PanelMeetingReminders`), its common
  lead times a click away. Drawn inside the form `PanelNewForm`
  draws, so a change reaches `panel:draft_change` like any other field.
  Each box and the toggle sit in a 44px row below 640px, where the panel is
  a sheet under a thumb, and their labels fill the row so the whole row taps;
  the reminder picker's buttons and custom number get a 44px hit area there
  too.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias TymeslotWeb.Components.Shared.ReminderPicker
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelMeetingReminders

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :venues, :list, default: [], doc: "the organiser's saved locations"
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
      :if={PanelMeeting.guests?(@values)}
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
        <div>
          <div class="flex min-h-11 items-center sm:min-h-0 [&_label]:flex [&_label]:min-h-11 [&_label]:items-center sm:[&_label]:min-h-0">
            <.input
              type="checkbox"
              id="calendar-panel-meeting-main-participant"
              name="main_participant"
              value={@values["main_participant"]}
              label={dgettext("dashboard_calendar_events", "Main participant")}
            />
          </div>
          <p id="calendar-panel-meeting-main-participant-hint" class="text-token-xs text-tymeslot-500">
            {if @values["main_participant"],
              do:
                dgettext(
                  "dashboard_calendar_events",
                  "The main participant can move or cancel the meeting. Turn this off to invite everyone as an equal guest."
                ),
              else:
                dgettext(
                  "dashboard_calendar_events",
                  "Everyone is an equal guest who can accept or decline. Only you can move or cancel the meeting."
                )}
          </p>
        </div>
        <.input
          :if={@values["main_participant"]}
          id="calendar-panel-meeting-guest-name"
          name="guest_name"
          maxlength="255"
          value={@values["guest_name"]}
          label={dgettext("dashboard_calendar_events", "Guest name")}
          placeholder={dgettext("dashboard_calendar_events", "Ada Lovelace")}
        />
        <div>
          <.select
            id="calendar-panel-meeting-location"
            name="location_choice"
            label={dgettext("dashboard_calendar_events", "Location (optional)")}
            prompt={dgettext("dashboard_calendar_events", "No location")}
            options={location_options(@venues)}
            value={@values["location_choice"]}
          />
          <.input
            :if={@values["location_choice"] == "custom"}
            id="calendar-panel-meeting-location-custom"
            name="location_custom"
            value={@values["location_custom"]}
            maxlength={CreateAdHoc.custom_location_max_length()}
            placeholder={
              dgettext("dashboard_calendar_events", "An address, a room or a meeting point")
            }
            aria-label={dgettext("dashboard_calendar_events", "Custom location")}
          />
          <p class="mt-1 text-token-xs text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_events",
              "Shown on the calendar entry and in every invitation."
            )}
          </p>
        </div>
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
        <%!-- The picker's buttons and its custom row's number take a 44px
              hit area below 640px, where the panel is a sheet. --%>
        <div
          id="calendar-panel-meeting-reminders"
          class="max-sm:[&_button]:min-h-11 max-sm:[&_button]:min-w-11 max-sm:[&_input]:min-h-11"
        >
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

  # Grouped as `options_for_select/2` takes them; the saved locations are
  # left out when the organiser has none.
  defp location_options(venues) do
    saved =
      case venues do
        [] ->
          []

        _some ->
          [
            {dgettext("dashboard_calendar_events", "Saved locations"),
             Enum.map(venues, &{&1.name, "venue:#{&1.id}"})}
          ]
      end

    saved ++ [{dgettext("dashboard_calendar_events", "Custom location…"), "custom"}]
  end
end
