defmodule TymeslotWeb.Dashboard.Calendar.PanelActions do
  @moduledoc "The side panel's foot in the edit state: Duplicate and Delete."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :surface, :any, required: true

  @spec edit_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def edit_actions(assigns) do
    ~H"""
    <div class="flex justify-between gap-2 border-t border-tymeslot-100 pt-3">
      <.action_button
        id="calendar-panel-duplicate"
        variant={:secondary}
        size={:sm}
        icon="hero-document-duplicate"
        phx-click="panel:duplicate"
        phx-target={@surface}
      >
        {dgettext("dashboard_calendar", "Duplicate")}
      </.action_button>
      <.action_button
        id="calendar-panel-delete"
        variant={:danger_soft}
        size={:sm}
        icon="hero-trash"
        phx-click="panel:delete"
        phx-target={@surface}
      >
        {dgettext("dashboard_calendar", "Delete")}
      </.action_button>
    </div>
    """
  end
end
