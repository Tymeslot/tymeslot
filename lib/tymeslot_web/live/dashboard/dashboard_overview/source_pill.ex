defmodule TymeslotWeb.Dashboard.DashboardOverview.SourcePill do
  @moduledoc """
  The pill saying where an agenda entry came from: a Tymeslot booking or an
  event on a connected calendar. Shared by the agenda rows and the agenda
  detail modal so the two always label an entry the same way.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Feedback

  attr :source, :atom, required: true

  @spec source_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def source_pill(%{source: :tymeslot} = assigns) do
    ~H"""
    <Feedback.pill tone={:brand} uppercase>
      {dgettext("dashboard_home", "Booking")}
    </Feedback.pill>
    """
  end

  def source_pill(assigns) do
    ~H"""
    <Feedback.pill tone={:neutral} uppercase>
      {dgettext("dashboard_home", "Calendar")}
    </Feedback.pill>
    """
  end
end
