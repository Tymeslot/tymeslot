defmodule TymeslotWeb.OnboardingLive.WelcomeStep do
  @moduledoc """
  Welcome step component for the onboarding flow.

  Displays the welcome message and feature highlights to introduce
  users to Tymeslot's key capabilities.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the welcome step component.
  """
  @spec welcome_step(map()) :: Phoenix.LiveView.Rendered.t()
  def welcome_step(assigns) do
    ~H"""
    <div class="onboarding-step">
      <div class="mb-6">
        <div class="onboarding-welcome-icon">
          <.icon name="hero-calendar-days" class="w-10 h-10" />
        </div>
        <h1 class="onboarding-title">
          Welcome to Tymeslot!
        </h1>
        <p class="onboarding-subtitle">Let's get you set up in just a few steps</p>
      </div>

      <div class="onboarding-feature-list">
        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <.icon name="hero-clock" class="w-5 h-5" />
          </div>
          <div>
            <h3 class="onboarding-feature-title">Smart Scheduling</h3>
            <p class="onboarding-feature-description">
              Automatically sync with your calendar and avoid conflicts
            </p>
          </div>
        </div>

        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <.icon name="hero-video-camera" class="w-5 h-5" />
          </div>
          <div>
            <h3 class="onboarding-feature-title">Multi-Provider Video Meetings</h3>
            <p class="onboarding-feature-description">
              Choose from MiroTalk P2P, Google Meet, Teams, or custom video links
            </p>
          </div>
        </div>

        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <.icon name="hero-envelope" class="w-5 h-5" />
          </div>
          <div>
            <h3 class="onboarding-feature-title">Professional Notifications</h3>
            <p class="onboarding-feature-description">Automated email confirmations and reminders</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
