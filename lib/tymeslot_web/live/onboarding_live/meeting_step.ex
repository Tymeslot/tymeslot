defmodule TymeslotWeb.OnboardingLive.MeetingStep do
  @moduledoc """
  The meeting step of the onboarding flow, where the host defines the meeting
  people book with them. The layout draws its title and Continue button; the
  step's own content is still to come.
  """

  use Phoenix.Component

  @doc """
  Renders the meeting step.
  """
  @spec meeting_step(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_step(assigns) do
    ~H"""
    <div id="onboarding-meeting-step"></div>
    """
  end
end
