defmodule TymeslotWeb.Components.Dashboard.Meetings.RemindersSection do
  @moduledoc """
  The reminders a booking carries, as shown on its card in the meetings list.

  Read-only: a booking's reminders are fixed when it is made, and this says
  what they are and how far they have got. It is the only place a host can see
  them after the fact — the meeting type shows its *current* setting, which a
  booking made before a change no longer follows, and a quick-added meeting has
  no meeting type at all.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Notifications.ReminderSchedule
  alias TymeslotWeb.Components.CoreComponents

  attr :meeting, :map, required: true

  @spec reminders_section(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_section(assigns) do
    assigns = assign(assigns, :reminders, ReminderSchedule.with_status(assigns.meeting))

    ~H"""
    <%!-- When this booking reminds. Its own list, copied from the meeting type
          when it was booked, so it stays right for a booking made before that
          setting changed. Released bookings (cancelled, expired) have none
          left: their reminders were dropped with the booking. --%>
    <div
      :if={@reminders != []}
      class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50"
    >
      <div class="flex gap-4 items-start mb-4">
        <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
          <CoreComponents.icon name="hero-bell" class="w-4 h-4 text-tymeslot-400" />
        </div>
        <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mt-2">
          {dgettext("dashboard_bookings", "Reminders")}
        </p>
      </div>
      <ul class="space-y-2.5">
        <li :for={reminder <- @reminders} class="flex items-center justify-between gap-3">
          <span class="text-token-sm font-medium text-tymeslot-700">
            {reminder_label(reminder)}
          </span>
          <span class="text-token-xs font-bold text-tymeslot-500">
            {reminder_status_label(reminder.status)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  # --- Private helpers ---

  defp reminder_label(%{value: value, unit: "hours"}),
    do:
      dngettext(
        "dashboard_bookings",
        "%{count} hour before",
        "%{count} hours before",
        value
      )

  defp reminder_label(%{value: value, unit: "days"}),
    do:
      dngettext(
        "dashboard_bookings",
        "%{count} day before",
        "%{count} days before",
        value
      )

  defp reminder_label(%{value: value}),
    do:
      dngettext(
        "dashboard_bookings",
        "%{count} minute before",
        "%{count} minutes before",
        value
      )

  # Said as "not yet sent" rather than "scheduled": the card's own status badge
  # already uses that word for the booking itself, and one card carrying it
  # twice for two different things reads as a contradiction. The context keeps
  # a translator free to word the two apart as well.
  defp reminder_status_label(:sent),
    do: dpgettext("dashboard_bookings", "reminder status", "Sent")

  defp reminder_status_label(:not_sent),
    do: dpgettext("dashboard_bookings", "reminder status", "Not sent")

  defp reminder_status_label(:after_approval),
    do: dpgettext("dashboard_bookings", "reminder status", "After approval")

  defp reminder_status_label(:after_payment),
    do: dpgettext("dashboard_bookings", "reminder status", "After payment")

  defp reminder_status_label(:after_rescheduling),
    do: dpgettext("dashboard_bookings", "reminder status", "After rescheduling")

  defp reminder_status_label(:upcoming),
    do: dpgettext("dashboard_bookings", "reminder status", "Not yet sent")
end
