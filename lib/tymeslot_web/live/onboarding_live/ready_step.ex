defmodule TymeslotWeb.OnboardingLive.ReadyStep do
  @moduledoc """
  Ready step component for the onboarding flow.

  Displays the user's booking URL with a copy button. The "Go to dashboard"
  navigation button in the layout footer is the sole call to action.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

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
          id="onboarding-copy-booking-url"
          phx-hook="CopyOnClick"
          data-copy-text={@booking_url}
          data-copy-feedback={dgettext("onboarding_wizard", "Booking link copied!")}
          class="onboarding-url-copy-btn"
          title={dgettext("onboarding_wizard", "Copy booking link")}
        >
          <.icon name="hero-clipboard-document" class="w-5 h-5" />
        </button>
      </div>
    </div>
    """
  end
end
