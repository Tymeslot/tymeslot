defmodule TymeslotWeb.Dashboard.DashboardOverview.SourcePill do
  @moduledoc """
  The pill saying where an agenda entry came from: a Tymeslot booking or an
  event on a connected calendar. Shared by the agenda rows and the agenda
  detail modal so the two always label an entry the same way.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents

  attr :source, :atom, required: true

  @spec source_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def source_pill(%{source: :tymeslot} = assigns) do
    ~H"""
    <CoreComponents.pill tone={:brand}>{dgettext("dashboard_home", "Booking")}</CoreComponents.pill>
    """
  end

  def source_pill(assigns) do
    ~H"""
    <CoreComponents.pill tone={:neutral}>
      {dgettext("dashboard_home", "Calendar")}
    </CoreComponents.pill>
    """
  end
end
