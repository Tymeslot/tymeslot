defmodule TymeslotWeb.Components.Dashboard.Availability.ClearDayModal do
  @moduledoc """
  Modal component for confirming day settings clear.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a clear day settings confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `day_data` - Map containing day number and day_name (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming clear (required)

  ## Examples

      <ClearDayModal.clear_day_modal
        id="clear-day-modal"
        show={@show_clear_day_modal}
        day_data={@clear_day_modal_data}
        on_cancel={JS.push("hide_clear_day_modal", target: @myself)}
        on_confirm={JS.push("confirm_clear_day", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :day_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec clear_day_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def clear_day_modal(assigns) do
    ~H"""
    <CoreComponents.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_availability", "Clear Day Settings")}
      confirm_label={dgettext("dashboard_availability", "Clear All Settings")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <%= if @day_data do %>
        <%!-- phx-no-format: the HTML plugin collapses the trailing keyword
        argument onto the message line and the Elixir formatter splits it
        back out again, so the two never agree on this call. --%>
        <p phx-no-format>
          {dgettext(
            "dashboard_availability",
            "Are you sure you want to clear all settings for %{day}?",
            day: @day_data.day_name
          )}
        </p>
        <p class="text-tymeslot-500">
          {dgettext(
            "dashboard_availability",
            "This will remove all availability hours and breaks for this day. This action cannot be undone."
          )}
        </p>
      <% end %>
    </CoreComponents.confirm_modal>
    """
  end
end
