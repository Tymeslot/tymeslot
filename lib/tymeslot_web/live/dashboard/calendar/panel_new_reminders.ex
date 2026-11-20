defmodule TymeslotWeb.Dashboard.Calendar.PanelNewReminders do
  @moduledoc """
  The reminders of a plain calendar event made in the side panel's New event
  state: several, each a notification or an email at one of the lead times
  `ReminderForm.reminder_minutes_presets/0` lists, written to the calendar with
  the event, which then alerts the organiser on their own devices.

  The list is the form's `"event_reminders"`, canonical
  `%{method:, minutes_before:}` maps, cast with the rest of the draft
  (`CreateParams.cast/5` holds it to its own limit). The add row's choices reach
  the form with its changes, and Add sends `panel:draft_add_reminder` (`add/2`),
  a plain button so that Enter in the form never adds a reminder; the remove
  buttons send `panel:draft_drop_reminder` (`drop/3`). How many reminders the
  draft's calendar keeps, and by which methods, is the domain's rule
  (`CreateParams.reminder_capacity/1`): on Outlook or Exchange, which keep
  one notification, the row offers one and no method choice. A Tymeslot meeting sends reminder emails of its own
  (`PanelMeetingReminders`) and a group event has none, so the field gives way
  to them.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.CreateParams
  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Dashboard.Calendar.PanelNew
  alias TymeslotWeb.Dashboard.Calendar.PanelReminderList

  @type socket :: Phoenix.LiveView.Socket.t()

  # The add row's fields, kept in the form as they change.
  @row_fields ~w(event_reminder_minutes event_reminder_method)

  @doc "The add row's fields among a form change's `params`."
  @spec fields(map()) :: map()
  def fields(params), do: Map.take(params, @row_fields)

  @doc """
  The reminders the draft will be written with, on a calendar of
  `provider`: those it holds that the calendar keeps
  (`CreateParams.fit_reminders/2`).
  """
  @spec of(map(), String.t() | nil) :: [map()]
  def of(form, provider \\ nil),
    do: CreateParams.fit_reminders(form["event_reminders"] || [], provider)

  @doc "Whether a calendar of `provider` keeps a single reminder method only."
  @spec single?(String.t() | nil) :: boolean()
  def single?(provider), do: match?({_max, [_one]}, CreateParams.reminder_capacity(provider))

  @doc "The most reminders a calendar of `provider` takes."
  @spec max(String.t() | nil) :: pos_integer()
  def max(provider), do: provider |> CreateParams.reminder_capacity() |> elem(0)

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
             "method" => method(form, provider),
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

  # A calendar with one method takes that one, whatever the row last held.
  defp method(form, provider) do
    case CreateParams.reminder_capacity(provider) do
      {_max, [only]} -> Atom.to_string(only)
      _several -> form["event_reminder_method"] || "popup"
    end
  end

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
      <PanelReminderList.chips
        reminders={@reminders}
        remove={
          fn {_reminder, index} ->
            JS.push("panel:draft_drop_reminder", value: %{index: index}, target: @surface)
          end
        }
      />
      <div :if={!@full} class="flex flex-wrap items-end gap-2">
        <.select
          id="calendar-panel-new-reminder-minutes"
          name="event_reminder_minutes"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder time")}
          value={@values["event_reminder_minutes"]}
          options={PanelReminderList.minutes_options()}
        />
        <.select
          :if={!@single}
          id="calendar-panel-new-reminder-method"
          name="event_reminder_method"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder method")}
          value={@values["event_reminder_method"]}
          options={PanelReminderList.method_options()}
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
