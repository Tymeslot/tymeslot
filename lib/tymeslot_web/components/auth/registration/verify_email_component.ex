defmodule TymeslotWeb.Registration.VerifyEmailComponent do
  @moduledoc """
  Email verification component.

  Provides the UI for email verification prompts and
  resend functionality during the registration process.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Shared.Auth.IconComponents

  @doc """
  Renders the verify email page using shared auth components.
  """
  @spec verify_email_page(map()) :: Phoenix.LiveView.Rendered.t()
  def verify_email_page(assigns) do
    ~H"""
    <.auth_card_layout title="Verify Your Email">
      <:heading>
        <h2 class="text-fluid-sm sm:text-fluid-md md:text-fluid-lg font-bold text-primary-600 mb-6 sm:mb-8 font-heading tracking-tight text-center">
          Almost There!
        </h2>
      </:heading>

      <:form>
        <.email_verification_message />
        <div class="mt-6 sm:mt-8 space-y-3">
          <.resend_verification_button loading={assigns[:loading] || false} />
          <.simple_link_button href="/auth/login">
            Back to Login
          </.simple_link_button>
        </div>
      </:form>
    </.auth_card_layout>
    """
  end

  defp email_verification_message(assigns) do
    ~H"""
    <div class="text-center mb-5 sm:mb-6">
      <div class="mx-auto w-14 h-14 sm:w-16 sm:h-16 md:w-20 md:h-20 flex items-center justify-center rounded-full bg-gradient-to-r from-primary-600 to-accent-purple shadow-lg border-2 border-white/20 ring-1 ring-black/10 mb-3 sm:mb-4">
        <.email_verification_icon />
      </div>
      <p class="text-fluid-xs sm:text-fluid-sm text-neutral-500 max-w-md mx-auto">
        We've just sent you a verification email! Give it a minute to arrive, and don't forget to check your spam folder – those pesky filters sometimes get a bit too enthusiastic. 😊 Just click the link in the email and you'll be all set!
      </p>
      <%= if email = get_in(assigns, [:form_data, :email]) || get_in(assigns, [:unverified_user, :email]) do %>
        <div class="mt-4 p-3 bg-primary-50 rounded-lg">
          <p class="text-sm text-primary-700">
            Verification email sent to: <span class="font-medium">{email}</span>
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp resend_verification_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="resend_verification"
      disabled={@loading}
      class="w-full inline-flex justify-center items-center px-4 py-2 border border-primary-300 rounded-md shadow-sm text-sm font-medium text-primary-700 bg-white hover:bg-primary-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors duration-200"
    >
      <%= if @loading do %>
        <svg
          class="animate-spin -ml-1 mr-3 h-5 w-5 text-primary-700"
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
        >
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
          </circle>
          <path
            class="opacity-75"
            fill="currentColor"
            d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
          >
          </path>
        </svg>
        Sending...
      <% else %>
        <svg
          class="-ml-1 mr-2 h-5 w-5"
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
          />
        </svg>
        Resend Verification Email
      <% end %>
    </button>
    """
  end
end
