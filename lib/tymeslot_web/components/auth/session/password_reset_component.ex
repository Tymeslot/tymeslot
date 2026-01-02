defmodule TymeslotWeb.Session.PasswordResetComponent do
  @moduledoc """
  Password reset components for the auth library.

  Note: These components do not include a background.
  Parent applications should wrap these components with their own background styling.

  For the new_password_form component, the full HTML structure is provided since it's
  rendered directly by the controller. The body tag includes standard background classes
  that can be customized by the parent app's CSS.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.InputComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Shared.Auth.IconComponents
  import TymeslotWeb.Shared.PasswordToggleButtonComponent

  @doc """
  Renders the forgot password form using shared auth components.
  Apps should wrap this component with their own background.
  """
  @spec forgot_password_form(map()) :: Phoenix.LiveView.Rendered.t()
  def forgot_password_form(assigns) do
    assigns =
      assigns
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:loading, false)

    ~H"""
    <.auth_card_layout
      title="Reset Password"
      subtitle="Enter your email and we'll send you instructions to reset your password"
      flash={assigns[:flash] || %{}}
    >
      <:form>
        <.auth_form
          id="reset-password-form"
          class="space-y-10 sm:space-y-12"
          phx-submit="submit_reset_request"
          loading={@loading}
          csrf_token={@csrf_token}
        >
          <.standard_email_input
            name="email"
            errors={Map.get(@errors, :email, [])}
            value={Map.get(@form_data, :email, "")}
            phx-change="validate_reset_request"
          />

          <%= if Map.get(@errors, :general) do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-200 rounded-md">
              <p class="text-sm text-red-600">{@errors.general}</p>
            </div>
          <% end %>

          <.auth_button
            type="submit"
            class={if @loading, do: "opacity-50 cursor-not-allowed", else: ""}
          >
            <%= if @loading do %>
              <svg
                class="animate-spin -ml-1 mr-3 h-5 w-5 text-white"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
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
              Send Reset Instructions
            <% end %>
          </.auth_button>
        </.auth_form>
      </:form>
      <:footer>
        <.auth_footer
          prompt="Remember your password?"
          phx-click="navigate_to"
          phx-value-state="login"
          link_text="Log in"
        />
      </:footer>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the forgot password confirmation page using shared auth components.
  """
  @spec forgot_password_confirm_page(map()) :: Phoenix.LiveView.Rendered.t()
  def forgot_password_confirm_page(assigns) do
    ~H"""
    <.auth_card_layout title="Check Your Email">
      <:form>
        <div class="text-center mb-5 sm:mb-6">
          <div class="mx-auto w-12 h-12 sm:w-14 sm:h-14 flex items-center justify-center">
            <.email_verification_icon />
          </div>
          <p class="mt-3 sm:mt-4 text-xs sm:text-sm text-white/80 max-w-md mx-auto">
            We've sent password reset instructions to your email address. Please check your inbox and follow the link to reset your password.
          </p>
        </div>
        <div class="mt-4 sm:mt-6">
          <.auth_link_button href="/auth/login">
            Back to Login
          </.auth_link_button>
        </div>
      </:form>
      <:footer>
        <.auth_footer
          prompt="Didn't receive the email?"
          href="/auth/reset-password"
          link_text="Try again"
        />
      </:footer>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the new password form using shared auth components.
  """
  @spec new_password_form(map()) :: Phoenix.LiveView.Rendered.t()
  def new_password_form(assigns) do
    # Ensure assigns has all required keys
    assigns = Map.merge(%{flash: %{}}, assigns)

    ~H"""
    <.auth_card_layout
      title="Reset Your Password"
      subtitle="Create a strong password for your account"
    >
      <:form>
        <%= if error_message = Map.get(@flash, :error) || Map.get(@flash, "error") do %>
          <div class="mb-4 rounded-lg bg-red-50 p-4 text-sm text-red-800" role="alert">
            <p>{error_message}</p>
          </div>
        <% end %>

        <.auth_form
          id="new-password-form"
          class="space-y-4 sm:space-y-5"
          action={"/auth/reset-password/#{@reset_token}"}
          phx-submit="submit_password_reset"
          csrf_token={@csrf_token}
        >
          <input type="hidden" name="token" value={@reset_token} />
          <div class="space-y-1.5" id="password-toggle-container" phx-hook="PasswordToggle">
            <.form_label for="password-input" text="New Password" />
            <.auth_text_input
              id="password-input"
              name="password"
              type="password"
              placeholder="Enter your new password"
              required={true}
              class="text-sm sm:text-base"
              aria-describedby="password-requirements"
            >
              <.password_toggle_button id="password-toggle" />
            </.auth_text_input>
            <.password_requirements />
          </div>
          <div class="space-y-1.5">
            <.form_label for="confirm-password-input" text="Confirm New Password" />
            <.auth_text_input
              id="confirm-password-input"
              name="password_confirmation"
              type="password"
              placeholder="Confirm your new password"
              required={true}
              class="text-sm sm:text-base"
            >
              <.password_toggle_button id="confirm-password-toggle" />
            </.auth_text_input>
          </div>
          <div class="pt-2">
            <.auth_button type="submit">
              Set New Password
            </.auth_button>
          </div>
        </.auth_form>
      </:form>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the password changed confirmation page using shared auth components.
  """
  @spec new_password_set_page(map()) :: Phoenix.LiveView.Rendered.t()
  def new_password_set_page(assigns) do
    ~H"""
    <.auth_card_layout title="Password Changed!">
      <:form>
        <div class="text-center mb-5 sm:mb-6">
          <.success_icon />
          <h2 class="mt-3 sm:mt-4 text-sm sm:text-base font-semibold text-white">
            Password Successfully Changed
          </h2>
          <p class="mt-2 text-xs sm:text-sm text-white/80 max-w-md mx-auto">
            Your password has been successfully updated. You can now log in with your new credentials.
          </p>
        </div>
        <div class="mt-4 sm:mt-6">
          <.auth_link_button href="/auth/login">
            Go to Login Page
          </.auth_link_button>
        </div>
      </:form>
      <:footer>
        <.auth_footer prompt="Need help?" href="/contact" link_text="Contact Support" />
      </:footer>
    </.auth_card_layout>
    """
  end
end
