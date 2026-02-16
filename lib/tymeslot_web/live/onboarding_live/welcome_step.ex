defmodule TymeslotWeb.OnboardingLive.WelcomeStep do
  @moduledoc """
  Welcome step component for the onboarding flow.

  Displays the welcome message and feature highlights to introduce
  users to Tymeslot's key capabilities.
  """

  use Phoenix.Component

  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the welcome step component.
  """
  # No assigns used in this component - purely static HTML
  @spec welcome_step(map()) :: Phoenix.LiveView.Rendered.t()
  def welcome_step(assigns) do
    ~H"""
    <div class="onboarding-step">
      <div class="mb-4">
        <h1 class="onboarding-title">
          {StepConfig.step_title(:welcome)}
        </h1>
        <p class="onboarding-subtitle">{StepConfig.step_description(:welcome)}</p>
      </div>

      <div class="onboarding-feature-list">
        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <svg class="w-5 h-5 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </div>
          <div>
            <h3 class="onboarding-feature-title">Smart Availability</h3>
            <p class="onboarding-feature-description">
              Sync with your existing calendars to prevent double-bookings automatically.
            </p>
          </div>
        </div>

        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <svg class="w-5 h-5 text-cyan-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
            </svg>
          </div>
          <div>
            <h3 class="onboarding-feature-title">HD Video Meetings</h3>
            <p class="onboarding-feature-description">
              Native MiroTalk, Google Meet, and Teams integrations for every booking.
            </p>
          </div>
        </div>

        <div class="onboarding-feature-item">
          <div class="onboarding-feature-icon">
            <svg class="w-5 h-5 text-blue-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
            </svg>
          </div>
          <div>
            <h3 class="onboarding-feature-title">Automated Workflows</h3>
            <p class="onboarding-feature-description">Instant confirmations and reminders sent to you and your clients.</p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
