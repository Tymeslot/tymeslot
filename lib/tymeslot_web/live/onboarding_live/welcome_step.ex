defmodule TymeslotWeb.OnboardingLive.WelcomeStep do
  @moduledoc """
  Welcome step component for the onboarding flow.

  Displays feature preview items introducing users to Tymeslot's
  key capabilities: profile, calendar sync, and scheduling rules.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @doc """
  Renders the welcome step with three feature preview items.
  """
  @spec welcome_step(map()) :: Phoenix.LiveView.Rendered.t()
  def welcome_step(assigns) do
    ~H"""
    <div class="onboarding-feature-list">
      <div class="onboarding-feature-item">
        <div class="onboarding-feature-icon">
          <.icon name="hero-user-circle" class="w-5 h-5" />
        </div>
        <div>
          <h3 class="onboarding-feature-title">
            {dgettext("onboarding_wizard", "Your professional profile")}
          </h3>
          <p class="onboarding-feature-description">
            {dgettext(
              "onboarding_wizard",
              "Set up your name, booking link, and timezone so clients know who they're meeting."
            )}
          </p>
        </div>
      </div>

      <div class="onboarding-feature-item">
        <div class="onboarding-feature-icon">
          <.icon name="hero-calendar-days" class="w-5 h-5" />
        </div>
        <div>
          <h3 class="onboarding-feature-title">{dgettext("onboarding_wizard", "Calendar sync")}</h3>
          <p class="onboarding-feature-description">
            {dgettext(
              "onboarding_wizard",
              "Connect Google, Outlook, or CalDAV calendars to prevent double-bookings automatically."
            )}
          </p>
        </div>
      </div>

      <div class="onboarding-feature-item">
        <div class="onboarding-feature-icon">
          <.icon name="hero-adjustments-horizontal" class="w-5 h-5" />
        </div>
        <div>
          <h3 class="onboarding-feature-title">
            {dgettext("onboarding_wizard", "Scheduling rules")}
          </h3>
          <p class="onboarding-feature-description">
            {dgettext(
              "onboarding_wizard",
              "Define buffer times, booking windows, and minimum notice to stay in control."
            )}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
