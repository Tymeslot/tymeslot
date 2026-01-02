defmodule TymeslotWeb.Components.Dashboard.Integrations.ProviderCard do
  @moduledoc """
  Shared provider card component for calendar and video integrations.
  """
  use Phoenix.Component

  alias TymeslotWeb.Components.Icons.ProviderIcon

  attr :provider, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :button_text, :string, required: true
  attr :click_event, :string, required: true
  attr :target, :any, required: true
  attr :provider_value, :string, default: nil

  @spec provider_card(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_card(assigns) do
    ~H"""
    <div class={[
      "card-glass transition-all duration-200 cursor-pointer hover:scale-[1.02]",
      "p-6 border-2 hover:border-teal-400/50 flex flex-col h-full"
    ]}>
      <div class="flex items-start gap-4 mb-4 flex-1">
        <ProviderIcon.provider_icon provider={@provider} size="medium" />
        <div class="flex-1">
          <h3 class="text-lg font-semibold text-gray-800 mb-1">{@title}</h3>
          <p class="text-sm text-gray-600">{@description}</p>
        </div>
      </div>
      <button
        phx-click={@click_event}
        phx-target={@target}
        phx-value-provider={@provider_value}
        class="btn btn-secondary w-full"
      >
        {@button_text}
      </button>
    </div>
    """
  end
end
