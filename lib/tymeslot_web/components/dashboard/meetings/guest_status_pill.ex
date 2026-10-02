defmodule TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPill do
  @moduledoc """
  The pill showing how a guest has answered an invitation to a booking.

  Shared by the meeting card's guest list and the add-guest modal, so a guest
  reads the same in both places. Any status other than accepted or declined is
  an invitation still waiting for an answer.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents

  attr :status, :string, required: true

  @spec guest_status_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def guest_status_pill(assigns) do
    {tone, icon, label} = presentation(assigns.status)
    assigns = assign(assigns, tone: tone, icon: icon, label: label)

    ~H"""
    <CoreComponents.pill tone={@tone} icon={@icon} uppercase={false}>{@label}</CoreComponents.pill>
    """
  end

  defp presentation("accepted"),
    do: {:success, "hero-check-circle-mini", dgettext("dashboard_bookings", "Going")}

  defp presentation("declined"),
    do: {:danger, "hero-x-circle-mini", dgettext("dashboard_bookings", "Declined")}

  defp presentation(_pending),
    do: {:warning, "hero-clock-mini", dgettext("dashboard_bookings", "Awaiting reply")}
end
