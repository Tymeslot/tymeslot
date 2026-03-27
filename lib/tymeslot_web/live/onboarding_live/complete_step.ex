defmodule TymeslotWeb.OnboardingLive.CompleteStep do
  @moduledoc """
  Complete step component for the onboarding flow.

  Displays the completion message and provides guidance for next steps
  after onboarding is finished.
  """

  use Phoenix.Component

  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the completion step component.
  """
  # No assigns used in this component - purely static HTML
  @spec complete_step(map()) :: Phoenix.LiveView.Rendered.t()
  def complete_step(assigns) do
    ~H"""
    <div class="onboarding-step">
      <div class="mb-4">
        <h2 class="onboarding-title">{StepConfig.step_title(:complete)}</h2>
        <p class="onboarding-subtitle">{StepConfig.step_description(:complete)}</p>
      </div>

      <div class="space-y-4 text-left">
        <div class="bg-tymeslot-50/50 rounded-3xl p-6 border-2 border-tymeslot-50">
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight mb-4">Recommended Next Steps</h3>
          <ul class="space-y-3">
            <li class="flex items-center gap-4 group">
              <div class="w-10 h-10 rounded-xl bg-white shadow-sm flex items-center justify-center border border-tymeslot-100 group-hover:border-turquoise-200 transition-colors">
                <svg class="w-5 h-5 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
                </svg>
              </div>
              <span class="font-bold text-tymeslot-700">Connect your professional calendars</span>
            </li>
            <li class="flex items-center gap-4 group">
              <div class="w-10 h-10 rounded-xl bg-white shadow-sm flex items-center justify-center border border-tymeslot-100 group-hover:border-cyan-200 transition-colors">
                <svg class="w-5 h-5 text-cyan-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
                </svg>
              </div>
              <span class="font-bold text-tymeslot-700">Set up HD video conferencing</span>
            </li>
            <li class="flex items-center gap-4 group">
              <div class="w-10 h-10 rounded-xl bg-white shadow-sm flex items-center justify-center border border-tymeslot-100 group-hover:border-blue-200 transition-colors">
                <svg class="w-5 h-5 text-blue-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4" />
                </svg>
              </div>
              <span class="font-bold text-tymeslot-700">Customize your meeting types and durations</span>
            </li>
          </ul>
        </div>

        <div class="bg-turquoise-50/50 border-2 border-turquoise-100 rounded-2xl p-4 text-center">
          <p class="text-turquoise-800 font-bold text-sm">
            <span class="bg-turquoise-600 text-white px-2 py-0.5 rounded uppercase text-[10px] font-black mr-2">Tip</span>
            You can always adjust these settings later from your dashboard.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
