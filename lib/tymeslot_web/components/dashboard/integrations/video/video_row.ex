defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.VideoRow do
  @moduledoc """
  Renders a single video integration row with actions.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Helpers.IntegrationProviders

  attr :integration, :map, required: true
  attr :testing_connection, :any, default: nil
  attr :myself, :any, required: true
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]
  attr :health_state, :map, default: nil

  @spec video_row(map()) :: Phoenix.LiveView.Rendered.t()
  def video_row(assigns) do
    provider_display_name =
      IntegrationProviders.format_provider_name(:video, assigns.integration.provider)

    assigns = assign(assigns, :provider_display_name, provider_display_name)

    ~H"""
    <div class={[
      "card-glass transition-all duration-200",
      !@integration.is_active && "card-glass-unavailable"
    ]}>
      <!-- Top row: info + toggle -->
      <div class="flex items-start justify-between gap-4">
        <!-- Left: Info -->
        <div class="flex items-start gap-4 min-w-0">
          <ProviderIcon.provider_icon provider={@integration.provider} size={@icon_size} class="mt-1 flex-shrink-0" />

          <div class="min-w-0">
            <!-- Title -->
            <div class="flex items-center gap-2 mb-1">
              <h4 class="text-base font-bold text-tymeslot-900 truncate">
                <%= if @integration.name == @provider_display_name do %>
                  {@provider_display_name}
                <% else %>
                  {@integration.name}
                <% end %>
              </h4>
              <UIComponents.health_warning_badge
                :if={@health_state && @health_state.status == :unhealthy}
              />
            </div>

            <!-- Provider Type -->
            <div class="text-xs text-tymeslot-600 mb-2">
              <%= case @integration.provider do %>
                <% "google_meet" -> %>
                  <span class="font-semibold text-turquoise-700">OAuth Provider</span>
                <% "teams" -> %>
                  <span class="font-semibold text-turquoise-700">OAuth Provider</span>
                <% "mirotalk" -> %>
                  <span class="font-semibold text-blue-700">Self-Hosted</span>
                <% "custom" -> %>
                  <span class="font-semibold text-purple-700">Custom URL</span>
                <% _ -> %>
                  <span class="font-semibold text-tymeslot-600">Video Provider</span>
              <% end %>
            </div>

            <!-- Details -->
            <div class="text-sm text-tymeslot-600 break-all">
              <%= if @integration.is_active do %>
                <%= if @integration.provider in ["google_meet", "teams"] do %>
                  <span>Authenticated via OAuth</span>
                <% end %>
                <%= if @integration.base_url do %>
                  <span>{URI.parse(@integration.base_url).host}</span>
                <% end %>
                <%= if Map.get(@integration, :custom_meeting_url) do %>
                  <span><%= @integration.custom_meeting_url %></span>
                <% end %>
              <% else %>
                <span class="text-tymeslot-500 italic">Integration is currently disabled</span>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Desktop: actions + toggle inline -->
        <div class="hidden sm:flex items-center gap-1 flex-shrink-0">
          <%= if @integration.is_active do %>
            <button
              phx-click="test_connection"
              phx-value-id={@integration.id}
              phx-target={@myself}
              disabled={@testing_connection == @integration.id}
              class="btn btn-sm btn-secondary"
            >
              <%= if @testing_connection == @integration.id do %>
                <.icon name="hero-arrow-path" class="animate-spin h-4 w-4 mr-1" />
                Testing...
              <% else %>
                <.icon name="hero-check-circle" class="w-4 h-4 mr-1" />
                Test
              <% end %>
            </button>
          <% end %>

          <button
            phx-click="show"
            phx-value-id={@integration.id}
            phx-target="#edit-video-modal"
            class="text-tymeslot-500 hover:text-turquoise-600 transition-colors p-2"
            title="Edit Integration"
          >
            <.icon name="hero-pencil-square" class="w-5 h-5" />
          </button>

          <button
            phx-click="show"
            phx-value-id={@integration.id}
            phx-target="#delete-video-modal"
            class="text-tymeslot-500 hover:text-red-600 transition-colors p-2"
            title="Delete Integration"
          >
            <.icon name="hero-trash" class="w-5 h-5" />
          </button>

          <StatusSwitch.status_switch
            id={"video-toggle-#{@integration.id}"}
            checked={@integration.is_active}
            on_change="toggle_integration"
            target={@myself}
            phx_value_id={to_string(@integration.id)}
            size={:large}
            class="ring-2 ring-turquoise-300/50"
          />
        </div>

        <!-- Mobile: toggle only -->
        <div class="flex-shrink-0 sm:hidden">
          <StatusSwitch.status_switch
            id={"video-toggle-mobile-#{@integration.id}"}
            checked={@integration.is_active}
            on_change="toggle_integration"
            target={@myself}
            phx_value_id={to_string(@integration.id)}
            size={:large}
            class="ring-2 ring-turquoise-300/50"
          />
        </div>
      </div>

      <!-- Mobile: action buttons below -->
      <div class="flex items-center justify-end gap-1 mt-2 sm:hidden">
        <%= if @integration.is_active do %>
          <button
            phx-click="test_connection"
            phx-value-id={@integration.id}
            phx-target={@myself}
            disabled={@testing_connection == @integration.id}
            class="btn btn-sm btn-secondary"
          >
            <%= if @testing_connection == @integration.id do %>
              <.icon name="hero-arrow-path" class="animate-spin h-4 w-4 mr-1" />
              Testing...
            <% else %>
              <.icon name="hero-check-circle" class="w-4 h-4 mr-1" />
              Test
            <% end %>
          </button>
        <% end %>

        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#edit-video-modal"
          class="text-tymeslot-500 hover:text-turquoise-600 transition-colors p-2"
          title="Edit Integration"
        >
          <.icon name="hero-pencil-square" class="w-5 h-5" />
        </button>

        <button
          phx-click="show"
          phx-value-id={@integration.id}
          phx-target="#delete-video-modal"
          class="text-tymeslot-500 hover:text-red-600 transition-colors p-2"
          title="Delete Integration"
        >
          <.icon name="hero-trash" class="w-5 h-5" />
        </button>
      </div>
    </div>
    """
  end
end
