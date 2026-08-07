defmodule TymeslotWeb.OnboardingLive.SkipConfirmationModal do
  @moduledoc """
  Skip confirmation modal component for the onboarding flow.

  Asks the user to confirm if they want to skip the onboarding setup.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the skip confirmation modal component.
  """
  attr :show, :boolean, required: true

  @spec skip_confirmation_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def skip_confirmation_modal(assigns) do
    ~H"""
    <CoreComponents.modal
      id="skip-onboarding-modal"
      show={@show}
      on_cancel={JS.push("hide_skip_modal")}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-4">
          <div class="w-12 h-12 bg-amber-50 rounded-2xl flex items-center justify-center border border-amber-100">
            <svg class="w-6 h-6 text-amber-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
              />
            </svg>
          </div>
          {dgettext("onboarding_wizard", "Skip setup?")}
        </div>
      </:header>

      <p class="text-tymeslot-600 font-medium text-token-lg leading-relaxed">
        {dgettext(
          "onboarding_wizard",
          "Are you sure you want to skip the quick start? You can always configure these settings later in your dashboard."
        )}
      </p>

      <:footer>
        <div class="flex flex-row gap-3">
          <CoreComponents.action_button
            variant={:danger}
            phx-click="skip_onboarding"
            class="flex-1 py-3"
          >
            {dgettext("onboarding_wizard", "Skip anyway")}
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:secondary}
            phx-click="hide_skip_modal"
            class="flex-1 py-3"
          >
            {dgettext("onboarding_wizard", "Continue setup")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
