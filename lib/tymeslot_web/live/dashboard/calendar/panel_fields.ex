defmodule TymeslotWeb.Dashboard.Calendar.PanelFields do
  @moduledoc """
  The side panel's plain fields: what a title, place or notes edit writes,
  the Busy/Free switch, and the reminder choice.

  Text goes through `CreateParams.clean_text/2`, the rule a create uses (title
  500, place 1,000, notes 5,000 characters, a title never blank). The reminder field offers None and
  the lead times `ReminderForm` allows, as one notification; every other
  alarm the event carries (an email, a lead time another app set, a second
  notification) is kept as it is and listed under the field.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.Integrations.Calendar.Reminder
  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RemindersEditor
  alias TymeslotWeb.Dashboard.Calendar.Creation

  @text_fields %{
    "title" => {:summary, :title},
    "location" => {:location, :location},
    "notes" => {:description, :description}
  }

  @doc """
  The change a text field's `value` makes (`field` is the event the panel
  sends: `"title"`, `"location"` or `"notes"`), or why it cannot be saved.
  """
  @spec text_change(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def text_change(field, value) when is_binary(value) do
    {key, create_field} = Map.fetch!(@text_fields, field)

    case CreateParams.clean_text(create_field, value) do
      {:ok, clean} -> {:ok, %{key => clean}}
      {:error, _field, reason} -> {:error, Creation.refusal_message(create_field, reason)}
    end
  end

  @doc "The `transparency` a Busy/Free choice writes."
  @spec transparency(String.t()) :: String.t()
  def transparency("free"), do: "transparent"
  def transparency("busy"), do: "opaque"

  @doc """
  The reminders an event carrying `reminders` gets when the field is set to
  `choice` (`"none"` or a lead time in minutes): the notification the field
  shows is replaced or removed, every other alarm kept. `:error` for a lead
  time the field does not offer. The same choice as now answers the list
  unchanged, so it writes nothing.
  """
  @spec reminders([map()], String.t()) :: {:ok, [map()]} | :error
  def reminders(reminders, choice) do
    cond do
      choice == choice(reminders) -> {:ok, reminders}
      choice == "none" -> {:ok, others(reminders)}
      true -> with_notification(reminders, choice)
    end
  end

  defp with_notification(reminders, minutes) do
    case ReminderForm.parse_reminder(%{"method" => "popup", "minutes" => minutes}) do
      {:ok, reminder} -> {:ok, [reminder | others(reminders)]}
      :error -> :error
    end
  end

  # The one notification the field shows: the first popup at a lead time it
  # offers.
  defp primary(reminders), do: Enum.find(reminders, &offered?/1)

  defp others(reminders), do: List.delete(reminders, primary(reminders))

  defp offered?(reminder),
    do:
      Reminder.method(reminder) == :popup and
        Reminder.minutes_before(reminder) in ReminderForm.reminder_minutes_presets()

  defp choice(reminders) do
    case primary(reminders) do
      nil -> "none"
      reminder -> reminder |> Reminder.minutes_before() |> Integer.to_string()
    end
  end

  attr :free, :boolean, required: true
  attr :target, :any, required: true

  @doc "Busy or Free, with what the choice means for bookings."
  @spec busy_free(map()) :: Phoenix.LiveView.Rendered.t()
  def busy_free(assigns) do
    ~H"""
    <div>
      <p class="label" aria-hidden="true">
        {dgettext("dashboard_calendar_editing", "Show me as")}
      </p>
      <.segmented_control
        id="calendar-panel-free"
        value={if @free, do: "free", else: "busy"}
        on_change="panel:free"
        target={@target}
        aria_label={dgettext("dashboard_calendar_editing", "Show me as")}
        size={:sm}
      >
        <:option value="busy" label={dgettext("dashboard_calendar_editing", "Busy")} />
        <:option value="free" label={dgettext("dashboard_calendar_editing", "Free")} />
      </.segmented_control>
      <p class="mt-1 text-token-xs text-tymeslot-500">
        {if @free,
          do: dgettext("dashboard_calendar_editing", "Guests can book this time"),
          else: dgettext("dashboard_calendar_editing", "Guests can't book this time")}
      </p>
    </div>
    """
  end

  attr :reminders, :list, required: true
  attr :disabled, :boolean, default: false
  attr :target, :any, required: true

  @doc "The reminder choice, with the event's other alarms listed under it."
  @spec reminder_field(map()) :: Phoenix.LiveView.Rendered.t()
  def reminder_field(assigns) do
    assigns =
      assign(assigns,
        choice: choice(assigns.reminders),
        others: others(assigns.reminders),
        options: reminder_options()
      )

    ~H"""
    <form id="calendar-panel-reminder" phx-change="panel:reminder" phx-target={@target} novalidate>
      <.select
        id="calendar-panel-reminder-choice"
        name="reminder"
        label={dgettext("dashboard_calendar_editing", "Reminder")}
        value={@choice}
        options={@options}
        disabled={@disabled}
      />
      <ul
        :if={@others != []}
        id="calendar-panel-other-reminders"
        class="mt-1 space-y-0.5 text-token-xs text-tymeslot-500"
        aria-label={dgettext("dashboard_calendar_editing", "Other reminders")}
      >
        <li :for={reminder <- @others}>{RemindersEditor.reminder_label(reminder)}</li>
      </ul>
    </form>
    """
  end

  defp reminder_options do
    [
      {dgettext("dashboard_calendar_editing", "None"), "none"}
      | Enum.map(
          ReminderForm.reminder_minutes_presets(),
          &{RemindersEditor.minutes_label(&1), Integer.to_string(&1)}
        )
    ]
  end
end
