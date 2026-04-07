defmodule TymeslotWeb.OnboardingLive.ReadyStep do
  @moduledoc """
  Ready step component for the onboarding flow.

  Displays the user's booking URL with a copy button and a link
  to explore the dashboard.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @doc """
  Renders the ready step with booking URL display.

  ## Attributes

  * `booking_url` - The user's full booking URL string
  """
  attr :booking_url, :string, required: true

  @spec ready_step(map()) :: Phoenix.LiveView.Rendered.t()
  def ready_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Booking URL display --%>
      <div class="onboarding-url-display">
        <.icon name="hero-link" class="w-5 h-5 text-tymeslot-400 shrink-0" />
        <span class="truncate">{@booking_url}</span>
        <button
          type="button"
          phx-click={
            Phoenix.LiveView.JS.dispatch("phx:copy", detail: %{text: @booking_url})
          }
          class="onboarding-url-copy-btn"
          title="Copy booking link"
        >
          <.icon name="hero-clipboard-document" class="w-5 h-5" />
        </button>
      </div>

      <%!-- Dashboard link --%>
      <div class="text-center">
        <a href="/dashboard" class="text-token-sm text-tymeslot-400 hover:text-tymeslot-600 font-medium transition-colors">
          or explore your dashboard first
        </a>
      </div>
    </div>
    """
  end
end
