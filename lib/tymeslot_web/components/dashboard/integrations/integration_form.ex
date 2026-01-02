defmodule TymeslotWeb.Components.Dashboard.Integrations.IntegrationForm do
  @moduledoc """
  Shared integration form component for calendar and video integrations.
  Provides consistent form handling and reduces code duplication.
  """
  use TymeslotWeb, :live_component

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex items-center justify-between mb-4">
        <h3 class="text-lg font-medium text-gray-800">
          {@title}
        </h3>
        <button
          phx-click={@cancel_event}
          phx-target={@target}
          class="text-gray-500 hover:text-gray-700"
        >
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </div>

      <%= if @provider_info do %>
        <div class="mb-4 p-3 bg-blue-900/20 border border-blue-500/30 rounded-lg">
          <div class="text-sm text-blue-200">
            <strong>Provider:</strong> {@provider_info}
          </div>
        </div>
      <% end %>

      <form phx-submit={@submit_event} phx-target={@target} class="space-y-4">
        {render_slot(@inner_block)}

        <%= if @show_errors and Map.get(@form_errors, :base) do %>
          <p class="text-sm text-red-400">{Enum.join(@form_errors[:base], ", ")}</p>
        <% end %>

        <div class="flex justify-end space-x-3">
          <button
            type="button"
            phx-click={@cancel_event}
            phx-target={@target}
            class="btn btn-secondary"
          >
            Cancel
          </button>
          <.submit_button saving={@saving} submit_text={@submit_text} />
        </div>
      </form>
    </div>
    """
  end

  defp submit_button(assigns) do
    ~H"""
    <button type="submit" disabled={@saving} class="btn btn-primary">
      <%= if @saving do %>
        <span class="flex items-center">
          <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
          Adding...
        </span>
      <% else %>
        {@submit_text || "Add Integration"}
      <% end %>
    </button>
    """
  end
end
