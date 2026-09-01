defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor do
  @moduledoc """
  Reusable reminders editor for the calendar create/detail modals.

  Renders the current reminders as removable rows plus an "Add reminder" control
  offering preset lead times and a method (popup/email). The lead times offered
  are exactly `Shared.reminder_minutes_presets/0`, the list `Shared.parse_reminder/1`
  validates an added reminder against, labelled through `reminder_label/1`'s own
  `minutes_label/1`; there is no second copy of the values to fall out of step.
  Reminders are synced to the calendar provider, which fires the alert on the
  user's own devices — Tymeslot does not fire them itself.

  Add/remove actions dispatch `add_event` / `remove_event` back to the owning
  LiveComponent via `phx-target`, carrying `method` + `minutes` (add) or `index`
  (remove). The owner threads the canonical
  `%{method: :popup | :email, minutes_before: integer}` shape through its state.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.Reminder
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  attr :reminders, :list, default: []
  attr :myself, :any, required: true
  attr :add_event, :string, required: true
  attr :remove_event, :string, required: true

  @spec reminders_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_editor(assigns) do
    assigns = assign(assigns, :presets, presets())

    ~H"""
    <div class="flex items-start gap-3 mb-3">
      <.icon name="hero-bell" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
      <div class="flex-1">
        <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">
          {dgettext("dashboard_calendar_events", "Reminders")}
        </p>

        <div :if={@reminders != []} class="flex flex-wrap gap-1.5 mb-2">
          <span
            :for={{reminder, index} <- Enum.with_index(@reminders)}
            class="inline-flex items-center gap-1 pl-2.5 pr-1 py-0.5 rounded-full bg-turquoise-50 border border-turquoise-200 text-token-xs text-turquoise-800"
          >
            {reminder_label(reminder)}
            <button
              type="button"
              phx-click={@remove_event}
              phx-value-index={index}
              phx-target={@myself}
              class="w-4 h-4 rounded-full hover:bg-red-100 flex items-center justify-center transition-colors"
              aria-label={
                dgettext("dashboard_calendar_events", "Remove reminder %{label}",
                  label: reminder_label(reminder)
                )
              }
            >
              <.icon name="hero-x-mark-micro" class="w-2.5 h-2.5" />
            </button>
          </span>
        </div>

        <form
          id="add-reminder-form"
          phx-submit={@add_event}
          phx-target={@myself}
          class="flex flex-wrap items-center gap-2"
        >
          <select
            name="minutes"
            class="rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
          >
            <option :for={{minutes, label} <- @presets} value={minutes}>{label}</option>
          </select>
          <select
            name="method"
            class="rounded-md border-tymeslot-300 text-token-xs text-tymeslot-700 focus:border-turquoise-500 focus:ring-turquoise-500 py-1"
          >
            <option value="popup">{dgettext("dashboard_calendar_events", "Notification")}</option>
            <option value="email">{dgettext("dashboard_calendar_events", "Email")}</option>
          </select>
          <button
            type="submit"
            class="px-2.5 py-1 rounded-md border border-tymeslot-300 text-token-xs text-tymeslot-600 hover:bg-tymeslot-50 transition-colors"
          >
            {dgettext("dashboard_calendar_events", "Add reminder")}
          </button>
        </form>
        <p class="text-token-xs text-tymeslot-400 mt-1">
          {dgettext(
            "dashboard_calendar_events",
            "Reminders are synced to your calendar so it can alert you on your own devices."
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Returns a human-readable label for a reminder, e.g. "Notification 10 minutes before".

  Reads through `Reminder`, so a raw string-keyed reminder straight out of the
  JSONB cache column labels the same as a canonical atom-keyed one. Rendering is
  the last place that should fail on a shape: a mislabelled reminder is a far
  cheaper outcome than a crashed calendar.
  """
  @spec reminder_label(map()) :: String.t()
  def reminder_label(%{} = reminder) do
    dgettext("dashboard_calendar_events", "%{method} %{minutes}",
      method: method_label(Reminder.method(reminder)),
      minutes: minutes_label(Reminder.minutes_before(reminder))
    )
  end

  defp method_label(:email), do: dgettext("dashboard_calendar_events", "Email")
  defp method_label(_popup_or_other), do: dgettext("dashboard_calendar_events", "Notification")

  # A provider alarm whose trigger we could not parse reaches the cache without
  # a lead time. Say so rather than inventing one.
  defp minutes_label(minutes) when not is_integer(minutes),
    do: dgettext("dashboard_calendar_events", "before the event")

  defp minutes_label(1440), do: dgettext("dashboard_calendar_events", "1 day before")
  defp minutes_label(60), do: dgettext("dashboard_calendar_events", "1 hour before")

  defp minutes_label(minutes) when minutes >= 60 and rem(minutes, 60) == 0,
    do:
      dngettext(
        "dashboard_calendar_events",
        "%{count} hour before",
        "%{count} hours before",
        div(minutes, 60)
      )

  defp minutes_label(minutes),
    do:
      dngettext(
        "dashboard_calendar_events",
        "%{count} minute before",
        "%{count} minutes before",
        minutes
      )

  # Offer exactly the lead times `parse_reminder/1` accepts, labelled by the same
  # function that labels a saved reminder. A value added to the whitelist shows
  # up here with a label already; one removed stops being offered.
  defp presets do
    Enum.map(Shared.reminder_minutes_presets(), &{&1, minutes_label(&1)})
  end
end
