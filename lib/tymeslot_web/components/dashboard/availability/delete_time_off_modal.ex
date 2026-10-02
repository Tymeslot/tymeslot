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
    <CoreComponents.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_availability", "Remove time off")}
      confirm_label={dgettext("dashboard_availability", "Remove")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <%= if @period_data do %>
        <p>
          {dgettext("dashboard_availability", "Remove your time off for %{range}?",
            range: Map.get(@period_data, :summary, "")
          )}
        </p>
        <p class="text-tymeslot-500">
          {dgettext("dashboard_availability", "Those days become bookable again straight away.")}
        </p>
      <% end %>
    </CoreComponents.confirm_modal>
    """
  end
end
