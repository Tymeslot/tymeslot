defmodule TymeslotWeb.OnboardingLive.CompleteStep do
  @moduledoc """
  Complete step component for the onboarding flow.

  Displays the completion message and provides guidance for next steps
  after onboarding is finished.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the completion step component.
  """
  @spec complete_step(map()) :: Phoenix.LiveView.Rendered.t()
  def complete_step(assigns) do
    ~H"""
    <div class="text-center">
      <div class="mb-6">
        <div class="onboarding-welcome-icon" style="background: rgba(22, 163, 74, 0.1);">
          <.icon name="hero-check-circle" class="w-10 h-10" style="color: #16a34a;" />
        </div>
        <h2 class="onboarding-title">You're All Set!</h2>
        <p class="onboarding-subtitle">Your Tymeslot account is ready to use</p>
      </div>

      <div class="space-y-4 text-left">
        <div class="bg-gray-100/50 rounded-lg p-4 border-2 border-gray-200">
          <h3 class="font-semibold text-gray-800 mb-2">What's Next?</h3>
          <ul class="space-y-2 text-gray-700">
            <li class="flex items-center space-x-2">
              <.icon name="hero-calendar" class="w-4 h-4 text-gray-800" />
              <span class="font-medium">Connect your calendar in the Calendar section</span>
            </li>
            <li class="flex items-center space-x-2">
              <.icon name="hero-video-camera" class="w-4 h-4 text-gray-800" />
              <span class="font-medium">Set up video integration for seamless meetings</span>
            </li>
            <li class="flex items-center space-x-2">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4 text-gray-800" />
              <span class="font-medium">Create custom meeting types with different durations</span>
            </li>
          </ul>
        </div>

        <div class="bg-purple-100/50 border border-purple-300 rounded-lg p-4">
          <p class="text-purple-800 text-sm">
            <strong>Pro tip:</strong> You can always adjust these settings later in your dashboard.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
