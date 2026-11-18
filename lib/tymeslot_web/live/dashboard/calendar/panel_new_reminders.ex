defmodule TymeslotWeb.Dashboard.Calendar.PanelNewReminders do
  @moduledoc """
  The reminders of a plain calendar event made in the side panel's New
  event state, as the old Quick Add offered them: several, each a
  notification or an email at one of the lead times
  `ReminderForm.reminder_minutes_presets/0` lists, written to the calendar
  with the event, which then alerts the organiser on their own devices.

  The list is the form's `"event_reminders"`, canonical
  `%{method:, minutes_before:}` maps, cast with the rest of the draft
  (`CreateParams.cast/5` holds it to its own limit). Add submits the New
  event form with `intent=add_reminder` (`add/2`), the remove buttons send
  `panel:draft_drop_reminder` (`drop/2`). A Tymeslot meeting sends reminder
  emails of its own (`PanelMeetingReminders`) and a group event has none,
  so the field gives way to them.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RemindersEditor
  alias TymeslotWeb.Dashboard.Calendar.PanelNew

  @type socket :: Phoenix.LiveView.Socket.t()

  # As many as `CreateParams` takes.
  @max 5

  @doc "The reminders a draft's form holds."
  @spec of(map()) :: [map()]
  def of(form), do: form["event_reminders"] || []

  @doc "The form's reminders as `CreateParams.cast/5` reads them."
  @spec params(map()) :: [map()]
  def params(form),
    do:
      Enum.map(
        of(form),
        &%{"method" => Atom.to_string(&1.method), "minutes" => &1.minutes_before}
      )

  @doc """
  Adds the reminder the add row holds (`"event_reminder_minutes"`,
  `"event_reminder_method"`); one the draft already has, one the row does
  not offer, or one past the limit adds nothing.
  """
  @spec add(socket(), map()) :: socket()
  def add(%{assigns: %{panel: %{form: form}}} = socket, params) do
    reminders = of(form)

    with true <- length(reminders) < @max,
         {:ok, reminder} <-
           ReminderForm.parse_reminder(%{
             "method" => params["event_reminder_method"],
             "minutes" => params["event_reminder_minutes"]
           }) do
      PanelNew.put_form(
        socket,
        Map.put(form, "event_reminders", ReminderForm.add_reminder(reminders, reminder))
      )
    else
      _not_added -> socket
    end
  end

  @doc "Drops the reminder at `index`."
  @spec drop(socket(), term()) :: socket()
  def drop(%{assigns: %{panel: %{form: form}}} = socket, index) do
    case Integer.parse(to_string(index)) do
      {at, ""} ->
        PanelNew.put_form(socket, Map.put(form, "event_reminders", List.delete_at(of(form), at)))

      _invalid ->
        socket
    end
  end

  attr :reminders, :list, required: true
  attr :surface, :any, required: true

  @doc "The event's reminders, each removable, and the row that adds one."
  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    assigns = assign(assigns, full: length(assigns.reminders) >= @max, max: @max)

    ~H"""
    <section id="calendar-panel-new-reminders" class="space-y-2">
      <h3 class="label mb-0">{dgettext("dashboard_calendar_editing", "Reminders")}</h3>
      <ul :if={@reminders != []} class="flex flex-wrap gap-1.5">
        <li
          :for={{reminder, index} <- Enum.with_index(@reminders)}
          class="inline-flex max-w-full items-center gap-1 rounded-token-full bg-tymeslot-100 py-0.5 pl-2.5 pr-1 text-token-sm text-tymeslot-800"
        >
          <span class="truncate">{RemindersEditor.reminder_label(reminder)}</span>
          <button
            type="button"
            phx-click={JS.push("panel:draft_drop_reminder", value: %{index: index}, target: @surface)}
            aria-label={
              dgettext("dashboard_calendar_editing", "Remove reminder %{label}",
                label: RemindersEditor.reminder_label(reminder)
              )
            }
            class="shrink-0 rounded-token-full p-0.5 text-tymeslot-500 hover:bg-tymeslot-200 hover:text-tymeslot-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 max-sm:min-h-11 max-sm:min-w-11"
          >
            <.icon name="hero-x-mark-micro" class="h-4 w-4" />
          </button>
        </li>
      </ul>
      <div :if={!@full} class="flex flex-wrap items-end gap-2">
        <.select
          id="calendar-panel-new-reminder-minutes"
          name="event_reminder_minutes"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder time")}
          options={
            Enum.map(
              ReminderForm.reminder_minutes_presets(),
              &{RemindersEditor.minutes_label(&1), Integer.to_string(&1)}
            )
          }
        />
        <.select
          id="calendar-panel-new-reminder-method"
          name="event_reminder_method"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder method")}
          options={[
            {dgettext("dashboard_calendar_events", "Notification"), "popup"},
            {dgettext("dashboard_calendar_events", "Email"), "email"}
          ]}
        />
        <.action_button
          id="calendar-panel-new-reminder-add"
          type="submit"
          name="intent"
          value="add_reminder"
          variant={:secondary}
          size={:sm}
        >
          {dgettext("dashboard_calendar_editing", "Add reminder")}
        </.action_button>
      </div>
      <p class="text-token-xs text-tymeslot-500">
        {dgettext(
          "dashboard_calendar_editing",
          "Reminders are synced to your calendar so it can alert you on your own devices."
        )}
      </p>
    </section>
    """
  end
end
