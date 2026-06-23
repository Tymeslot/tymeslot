defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor do
  @moduledoc """
  Reusable reminders editor for the calendar create/detail modals.

  Renders the current reminders as removable rows plus an "Add reminder" control
  offering preset lead times (5 min, 10 min, 30 min, 1 hour, 1 day before) and a
  method (popup/email). Reminders are synced to the calendar provider, which
  fires the alert on the user's own devices — Tymeslot does not fire them itself.

  Add/remove actions dispatch `add_event` / `remove_event` back to the owning
  LiveComponent via `phx-target`, carrying `method` + `minutes` (add) or `index`
  (remove). The owner threads the canonical
  `%{method: :popup | :email, minutes_before: integer}` shape through its state.
  """

  use TymeslotWeb, :html

  @presets [
    {5, "5 minutes before"},
    {10, "10 minutes before"},
    {30, "30 minutes before"},
    {60, "1 hour before"},
    {1440, "1 day before"}
  ]

  attr :reminders, :list, default: []
  attr :myself, :any, required: true
  attr :add_event, :string, required: true
  attr :remove_event, :string, required: true

  @spec reminders_editor(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_editor(assigns) do
    assigns = assign(assigns, :presets, @presets)

    ~H"""
    <div class="flex items-start gap-3 mb-3">
      <.icon name="hero-bell" class="w-4 h-4 text-tymeslot-400 mt-0.5 shrink-0" />
      <div class="flex-1">
        <p class="text-token-xs font-medium text-tymeslot-400 mb-1.5">Reminders</p>

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
              aria-label={"Remove reminder #{reminder_label(reminder)}"}
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
            <option value="popup">Notification</option>
            <option value="email">Email</option>
          </select>
          <button
            type="submit"
            class="px-2.5 py-1 rounded-md border border-tymeslot-300 text-token-xs text-tymeslot-600 hover:bg-tymeslot-50 transition-colors"
          >
            Add reminder
          </button>
        </form>
        <p class="text-token-xs text-tymeslot-400 mt-1">
          Reminders are synced to your calendar so it can alert you on your own devices.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Returns a human-readable label for a reminder, e.g. "Notification 10 minutes before".
  """
  @spec reminder_label(map()) :: String.t()
  def reminder_label(%{method: method, minutes_before: minutes}) do
    "#{method_label(method)} #{minutes_label(minutes)}"
  end

  defp method_label(:email), do: "Email"
  defp method_label(_popup_or_other), do: "Notification"

  defp minutes_label(1440), do: "1 day before"
  defp minutes_label(60), do: "1 hour before"

  defp minutes_label(minutes) when minutes >= 60 and rem(minutes, 60) == 0,
    do: "#{div(minutes, 60)} hours before"

  defp minutes_label(minutes), do: "#{minutes} minutes before"
end
