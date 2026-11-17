defmodule TymeslotWeb.Dashboard.Calendar.PanelMeetingFields do
  @moduledoc """
  The New event form's meeting fields (see `PanelMeeting`): the "Send as a
  Tymeslot meeting" box, offered once the draft has a guest, and while it
  is ticked the guest's name, the language of every email about the
  meeting and its reminder emails. Drawn inside the form `PanelNewForm`
  draws, so a change reaches `panel:draft_change` like any other field.
  Each box and the toggle sit in a 44px row below 640px, where the panel is
  a sheet under a thumb, and their labels fill the row so the whole row taps.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"

  @spec meeting_fields(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_fields(assigns) do
    assigns = assign(assigns, :on, PanelMeeting.on?(assigns.values))

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
        <fieldset id="calendar-panel-meeting-reminders" class="space-y-1">
          <legend class="label">{dgettext("common", "Reminders")}</legend>
          <%!-- Sent with the boxes so that ticking none still sends the field. --%>
          <input type="hidden" name="reminders[]" value="" />
          <div
            :for={{key, label} <- reminder_choices()}
            class="flex min-h-11 items-center sm:min-h-0 [&_label]:flex [&_label]:min-h-11 [&_label]:items-center sm:[&_label]:min-h-0"
          >
            <.input
              type="checkbox"
              id={"calendar-panel-meeting-reminder-#{key}"}
              name="reminders[]"
              value={key}
              checked={key in @values["reminders"]}
              label={label}
            />
          </div>
          <p class="text-token-xs text-tymeslot-500">
            {dngettext(
              "dashboard_calendar_events",
              "Add up to %{count} reminder email for this meeting. The guest and anyone else invited receive it.",
              "Add up to %{count} reminder emails for this meeting. The guest and anyone else invited receive it.",
              ReminderValidation.max_reminders()
            )}
          </p>
        </fieldset>
      </div>
    </section>
    """
  end

  defp reminder_choices do
    labels = %{
      "30_minutes" => dgettext("common", "30 min. before"),
      "1_hours" => dgettext("common", "1 hour before"),
      "1_days" => dgettext("dashboard_calendar_events", "1 day before")
    }

    Enum.map(MeetingParams.reminder_choices(), &{&1, Map.fetch!(labels, &1)})
  end
end
