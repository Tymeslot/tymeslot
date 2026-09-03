defmodule TymeslotWeb.Components.Dashboard.Availability.DeleteTimeOffModal do
  @moduledoc """
  Confirmation modal for removing a time-off period.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the delete confirmation for one period.

  `period_data` carries `:id` and `:summary`, the same range text the list
  row shows, so the dialog names the period the row it came from named.
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :period_data, :map, default: nil
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_time_off_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_time_off_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <CoreComponents.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-500" />
          {dgettext("dashboard_availability", "Remove time off")}
        </div>
      </:header>

      <div :if={@period_data} class="space-y-4">
        <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
          {dgettext("dashboard_availability", "Remove your time off for %{range}?",
            range: Map.get(@period_data, :summary, "")
          )}
        </p>
        <p class="text-tymeslot-500 font-medium">
          {dgettext("dashboard_availability", "Those days become bookable again straight away.")}
        </p>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
            {dgettext("dashboard_availability", "Remove")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
