defmodule TymeslotWeb.Dashboard.Calendar.PanelNewReminders do
  @moduledoc """
  The reminders of a plain calendar event made in the side panel's New
  event state, as the old Quick Add offered them: several, each a
  notification or an email at one of the lead times
  `ReminderForm.reminder_minutes_presets/0` lists, written to the calendar
  with the event, which then alerts the organiser on their own devices.

  The list is the form's `"event_reminders"`, canonical
  `%{method:, minutes_before:}` maps, cast with the rest of the draft
  (`CreateParams.cast/5` holds it to its own limit). The add row's choices
  reach the form with its changes, and Add sends `panel:draft_add_reminder`
  (`add/2`), a plain button so that Enter in the form never adds a
  reminder; the remove buttons send `panel:draft_drop_reminder` (`drop/3`).
  An Outlook calendar keeps a single lead time and no method, so there the
  row offers one notification and no method choice. A Tymeslot meeting sends reminder
  emails of its own (`PanelMeetingReminders`) and a group event has none,
  so the field gives way to them.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.CreateParams
  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RemindersEditor
  alias TymeslotWeb.Dashboard.Calendar.PanelNew

  @type socket :: Phoenix.LiveView.Socket.t()

  # The add row's fields, kept in the form as they change.
  @row_fields ~w(event_reminder_minutes event_reminder_method)

  # Outlook keeps one lead time per event and no method
  # (`Outlook.EventMapper`): a second reminder, or an email, would never
  # reach it.
  @single_reminder_providers ["outlook"]

  @doc "The add row's fields among a form change's `params`."
  @spec fields(map()) :: map()
  def fields(params), do: Map.take(params, @row_fields)

  @doc """
  The reminders the draft will be written with, on a calendar of
  `provider`: all it holds, or for Outlook the first as a notification.
  """
  @spec of(map(), String.t() | nil) :: [map()]
  def of(form, provider \\ nil) do
    reminders = form["event_reminders"] || []

    if single?(provider),
      do: reminders |> Enum.take(1) |> Enum.map(&%{&1 | method: :popup}),
      else: reminders
  end

  @doc "Whether a calendar of `provider` takes a single notification only."
  @spec single?(String.t() | nil) :: boolean()
  def single?(provider), do: provider in @single_reminder_providers

  @doc "The most reminders a calendar of `provider` takes."
  @spec max(String.t() | nil) :: pos_integer()
  def max(provider), do: if(single?(provider), do: 1, else: CreateParams.max_reminders())

  @doc "The form's reminders as `CreateParams.cast/5` reads them, for a calendar of `provider`."
  @spec params(map(), String.t() | nil) :: [map()]
  def params(form, provider),
    do:
      Enum.map(
        of(form, provider),
        &%{"method" => Atom.to_string(&1.method), "minutes" => &1.minutes_before}
      )

  @doc """
  Adds the reminder the add row holds, as the form last heard it
  (`"event_reminder_minutes"`, `"event_reminder_method"`; the row's first
  choices until one changes), on a calendar of `provider`. One the draft
  already has, one the row does not offer, or one past the limit adds
  nothing.
  """
  @spec add(socket(), String.t() | nil) :: socket()
  def add(%{assigns: %{panel: %{form: form}}} = socket, provider) do
    reminders = of(form, provider)

    with true <- length(reminders) < max(provider),
         {:ok, reminder} <-
           ReminderForm.parse_reminder(%{
             "method" => if(single?(provider), do: "popup", else: method(form)),
             "minutes" => minutes(form)
           }) do
      PanelNew.put_form(
        socket,
        Map.put(form, "event_reminders", ReminderForm.add_reminder(reminders, reminder))
      )
    else
      _not_added -> socket
    end
  end

  defp minutes(form),
    do:
      form["event_reminder_minutes"] ||
        Integer.to_string(hd(ReminderForm.reminder_minutes_presets()))

  defp method(form), do: form["event_reminder_method"] || "popup"

  @doc "Drops the reminder at `index`."
  @spec drop(socket(), term(), String.t() | nil) :: socket()
  def drop(%{assigns: %{panel: %{form: form}}} = socket, index, provider) do
    case Integer.parse(to_string(index)) do
      {at, ""} ->
        PanelNew.put_form(
          socket,
          Map.put(form, "event_reminders", List.delete_at(of(form, provider), at))
        )

      _invalid ->
        socket
    end
  end

  attr :values, :map, required: true, doc: "the typed values (`panel.form`)"
  attr :provider, :string, default: nil, doc: "the provider of the draft's calendar"
  attr :surface, :any, required: true

  @doc "The event's reminders, each removable, and the row that adds one."
  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    reminders = of(assigns.values, assigns.provider)

    assigns =
      assign(assigns,
        reminders: reminders,
        full: length(reminders) >= max(assigns.provider),
        single: single?(assigns.provider)
      )

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
          value={@values["event_reminder_minutes"]}
          options={
            Enum.map(
              ReminderForm.reminder_minutes_presets(),
              &{RemindersEditor.minutes_label(&1), Integer.to_string(&1)}
            )
          }
        />
        <.select
          :if={!@single}
          id="calendar-panel-new-reminder-method"
          name="event_reminder_method"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder method")}
          value={@values["event_reminder_method"]}
          options={[
            {dgettext("dashboard_calendar_events", "Notification"), "popup"},
            {dgettext("dashboard_calendar_events", "Email"), "email"}
          ]}
        />
        <%!-- A plain button, not a submit: Enter in the form's fields must
              reach the guest field's Add, its first submit button. --%>
        <.action_button
          id="calendar-panel-new-reminder-add"
          type="button"
          phx-click="panel:draft_add_reminder"
          phx-target={@surface}
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
