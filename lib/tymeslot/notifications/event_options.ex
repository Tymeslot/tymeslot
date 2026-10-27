defmodule Tymeslot.Notifications.EventOptions do
  @moduledoc """
  The meeting notification events as the automation dashboards offer them:
  each wire name of `Tymeslot.Notifications.EventTypes` with its translated
  label and description.

  This is the one list every channel's dashboard form offers, so a channel
  can neither subscribe to an event its form does not show (where the first
  edit would silently drop it) nor fall behind when an event is added.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Notifications.EventTypes

  @type option :: %{value: String.t(), label: String.t(), description: String.t()}

  @doc """
  Every event of `EventTypes.all/0`, in that order, with the label and description the
  dashboard shows for it, translated into the current locale. Webhooks,
  Slack and Telegram all offer exactly this list.
  """
  @spec options() :: [option()]
  def options do
    Enum.map(EventTypes.all(), fn value ->
      %{value: value, label: event_label(value), description: event_description(value)}
    end)
  end

  defp event_label("meeting.created"), do: dgettext("dashboard_automation", "Meeting Created")
  defp event_label("meeting.requested"), do: dgettext("dashboard_automation", "Booking Requested")
  defp event_label("meeting.declined"), do: dgettext("dashboard_automation", "Booking Declined")

  defp event_label("meeting.request_expired"),
    do: dgettext("dashboard_automation", "Booking Request Expired")

  defp event_label("meeting.cancelled"), do: dgettext("dashboard_automation", "Meeting Cancelled")

  defp event_label("meeting.rescheduled"),
    do: dgettext("dashboard_automation", "Meeting Rescheduled")

  # Catch-all so a future `EventTypes` entry with no dedicated copy yet
  # renders something readable on the automation dashboard instead of
  # crashing `available_events/0` (and the page that calls it).
  defp event_label(value), do: value

  defp event_description("meeting.created"),
    do: dgettext("dashboard_automation", "Triggers when a new booking is successfully created")

  defp event_description("meeting.requested"),
    do:
      dgettext(
        "dashboard_automation",
        "Triggers when someone requests a booking on a meeting type that needs your approval"
      )

  defp event_description("meeting.declined"),
    do: dgettext("dashboard_automation", "Triggers when you decline a booking request")

  defp event_description("meeting.request_expired"),
    do:
      dgettext(
        "dashboard_automation",
        "Triggers when nobody answers a booking request before its deadline"
      )

  defp event_description("meeting.cancelled"),
    do: dgettext("dashboard_automation", "Triggers when an existing booking is cancelled")

  defp event_description("meeting.rescheduled"),
    do: dgettext("dashboard_automation", "Triggers when a booking time is changed")

  defp event_description(_value),
    do: dgettext("dashboard_automation", "Triggers on this event")
end
