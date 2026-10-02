defmodule TymeslotWeb.Components.Dashboard.Integrations.IntegrationForm do
  @moduledoc """
  Shared integration form component for calendar and video integrations.
  Provides consistent form handling and reduces code duplication.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-medium text-tymeslot-800">
          {@title}
        </h3>
        <.icon_button
          icon="hero-x-mark"
          label={dgettext("dashboard_integrations", "Close")}
          phx-click={@cancel_event}
          phx-target={@target}
        />
      </div>

      <%= if @provider_info do %>
        <div class="mb-4 p-3 bg-blue-900/20 border border-blue-500/30 rounded-lg">
          <div class="text-sm text-blue-200">
            <strong>{dgettext("dashboard_integrations", "Provider:")}</strong> {@provider_info}
          </div>
        </div>
      <% end %>

      <form
        id={"integration-form-#{@target}"}
        phx-submit={@submit_event}
        phx-target={@target}
        class="space-y-4"
      >
        {render_slot(@inner_block)}

        <%= if @show_errors and FormValidationHelpers.field_errors(@form_errors, :base) != [] do %>
          <p class="text-sm text-red-400">
            {Enum.join(FormValidationHelpers.field_errors(@form_errors, :base), ", ")}
          </p>
        <% end %>

        <div class="flex justify-end space-x-3">
          <.action_button variant={:secondary} phx-click={@cancel_event} phx-target={@target}>
            {dgettext("dashboard_integrations", "Cancel")}
          </.action_button>
          <.loading_button
            type="submit"
            loading={@saving}
            loading_text={dgettext("dashboard_integrations", "Adding...")}
          >
            {@submit_text || dgettext("dashboard_integrations", "Add Integration")}
          </.loading_button>
        </div>
      </form>
    </div>
    """
  end
end
