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
  use Gettext, backend: TymeslotWeb.Gettext
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Shared.PasswordToggleButtonComponent
  import TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

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
      title={dgettext("auth", "Reset Password")}
      subtitle={
        dgettext("auth", "Enter your email and we'll send you instructions to reset your password")
      }
      flash={assigns[:flash] || %{}}
    >
      <:form>
        <.auth_form
          id="reset-password-form"
          class="space-y-6"
          phx-submit="submit_reset_request"
          loading={@loading}
          csrf_token={@csrf_token}
        >
          <.input
            name="email"
            type="email"
            label={dgettext("auth", "Email Address")}
            errors={FormValidationHelpers.field_errors(@errors, :email)}
            value={Map.get(@form_data, :email, "")}
            phx-change="validate_reset_request"
            phx-debounce="blur"
            icon="hero-envelope"
            required
            autofocus
          />

          <%= if FormValidationHelpers.field_errors(@errors, :general) != [] do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-200 rounded-md">
              <%= for message <- FormValidationHelpers.field_errors(@errors, :general) do %>
                <p class="text-sm text-red-600">{message}</p>
              <% end %>
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
              {dgettext("auth", "Sending...")}
            <% else %>
              {dgettext("auth", "Send Reset Instructions")}
            <% end %>
          </.auth_button>
        </.auth_form>
      </:form>
      <:footer>
        <.auth_footer
          prompt={dgettext("auth", "Remember your password?")}
          phx-click="navigate_to"
          phx-value-state="login"
          link_text={dgettext("auth", "Log in")}
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
    <.auth_card_layout title={dgettext("auth", "Check Your Email")}>
      <:form>
        <div class="text-center mb-8">
          <div class="mx-auto w-20 h-20 flex items-center justify-center rounded-2xl bg-turquoise-50 border-2 border-turquoise-100 shadow-xl shadow-turquoise-500/10 mb-6 transform hover:scale-105 transition-all duration-300">
            <svg class="w-10 h-10 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
            </svg>
          </div>
          <p class="text-base text-tymeslot-600 font-medium max-w-md mx-auto leading-relaxed">
            {dgettext(
              "auth",
              "We've sent password reset instructions to your email address. Please check your inbox and follow the link to reset your password."
            )}
          </p>
        </div>
        <div class="mt-8 text-center">
          <.auth_link_button href={~p"/auth/login"} class="inline-block">
            {dgettext("auth", "Back to Login")}
          </.auth_link_button>
        </div>
      </:form>
      <:footer>
        <.auth_footer
          prompt={dgettext("auth", "Didn't receive the email?")}
          href={~p"/auth/reset-password"}
          link_text={dgettext("auth", "Try again")}
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
      title={dgettext("auth", "Reset Your Password")}
      subtitle={dgettext("auth", "Create a strong password for your account")}
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
          action={~p"/auth/reset-password/#{@reset_token}"}
          phx-submit="submit_password_reset"
          csrf_token={@csrf_token}
        >
          <input type="hidden" name="token" value={@reset_token} />
          <div class="space-y-1.5" id="reset-password-toggle-container" phx-hook="PasswordToggle" data-password-container>
            <.input
              id="password-input"
              name="password"
              type="password"
              label={dgettext("auth", "New Password")}
              placeholder={dgettext("auth", "Enter your new password")}
              required
              autofocus
              class="text-sm sm:text-base"
              aria-describedby="password-requirements"
              icon="hero-lock-closed"
            >
              <:trailing_icon>
                <.password_toggle_button id="password-toggle" />
              </:trailing_icon>
            </.input>
            <.password_requirements />
          </div>
          <div class="space-y-1.5" id="reset-confirm-password-toggle-container" phx-hook="PasswordToggle" data-password-container>
            <.input
              id="confirm-password-input"
              name="password_confirmation"
              type="password"
              label={dgettext("auth", "Confirm New Password")}
              placeholder={dgettext("auth", "Confirm your new password")}
              required
              class="text-sm sm:text-base"
              icon="hero-lock-closed"
            >
              <:trailing_icon>
                <.password_toggle_button id="confirm-password-toggle" />
              </:trailing_icon>
            </.input>
          </div>
          <div class="pt-2">
            <.auth_button type="submit">
              {dgettext("auth", "Set New Password")}
            </.auth_button>
          </div>
        </.auth_form>
      </:form>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the password reset success page within AuthLive.

  Shown after a user successfully resets their password via the LiveView flow.
  Provides a button to navigate back to the login state.
  """
  @spec password_reset_success(map()) :: Phoenix.LiveView.Rendered.t()
  def password_reset_success(assigns) do
    ~H"""
    <.auth_card_layout
      title={dgettext("auth", "Success!")}
      flash={assigns[:flash] || %{}}
    >
      <:form>
        <div class="text-center mb-8">
          <h2 class="text-xl font-bold text-tymeslot-900 tracking-tight mb-3">
            {dgettext("auth", "Password Reset Successfully")}
          </h2>
          <p class="text-base text-tymeslot-600 font-medium max-w-md mx-auto leading-relaxed">
            {dgettext("auth", "Your password has been reset. You can now log in with your new credentials.")}
          </p>
        </div>
        <div class="mt-6">
          <.auth_button
            phx-click="navigate_to"
            phx-value-state="login"
          >
            {dgettext("auth", "Log In")}
          </.auth_button>
        </div>
      </:form>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the invalid/expired token page within AuthLive.

  Shown when a password reset link has expired or is otherwise invalid.
  Provides buttons to request a new link or return to login.
  """
  @spec invalid_token(map()) :: Phoenix.LiveView.Rendered.t()
  def invalid_token(assigns) do
    ~H"""
    <.auth_card_layout
      title={dgettext("auth", "Invalid Link")}
      flash={assigns[:flash] || %{}}
    >
      <:form>
        <div class="text-center mb-8">
          <div class="mx-auto w-20 h-20 flex items-center justify-center rounded-2xl bg-red-50 border-2 border-red-100 shadow-xl shadow-red-500/10 mb-6 transform hover:scale-105 transition-all duration-300">
            <svg class="w-10 h-10 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </div>
          <h2 class="text-xl font-bold text-tymeslot-900 tracking-tight mb-3">
            {dgettext("auth", "Link Expired or Invalid")}
          </h2>
          <p class="text-base text-tymeslot-600 font-medium max-w-md mx-auto leading-relaxed">
            {dgettext(
              "auth",
              "The security link you followed is no longer valid. Please request a new one to continue."
            )}
          </p>
        </div>
        <div class="space-y-4">
          <.auth_button
            phx-click="navigate_to"
            phx-value-state="reset_password"
          >
            {dgettext("auth", "Request New Link")}
          </.auth_button>
          <button
            type="button"
            phx-click="navigate_to"
            phx-value-state="login"
            class="btn-secondary w-full py-3.5"
          >
            {dgettext("auth", "Back to Login")}
          </button>
        </div>
      </:form>
    </.auth_card_layout>
    """
  end

  @doc """
  Renders the password changed confirmation page using shared auth components.
  """
  @spec new_password_set_page(map()) :: Phoenix.LiveView.Rendered.t()
  def new_password_set_page(assigns) do
    assigns = assign(assigns, :contact_url, Application.get_env(:tymeslot, :contact_url))

    ~H"""
    <.auth_card_layout title={dgettext("auth", "Success!")}>
      <:form>
        <div class="text-center mb-8">
          <div class="mx-auto w-20 h-20 flex items-center justify-center rounded-2xl bg-emerald-50 border-2 border-emerald-100 shadow-xl shadow-emerald-500/10 mb-6 transform hover:scale-105 transition-all duration-300">
            <svg class="w-10 h-10 text-emerald-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
          </div>
          <h2 class="text-xl font-bold text-tymeslot-900 tracking-tight mb-3">
            {dgettext("auth", "Password Changed")}
          </h2>
          <p class="text-base text-tymeslot-600 font-medium max-w-md mx-auto leading-relaxed">
            {dgettext(
              "auth",
              "Your password has been successfully updated. You can now log in with your new credentials."
            )}
          </p>
        </div>
        <div class="mt-8">
          <.auth_link_button href={~p"/auth/login"}>
            {dgettext("auth", "Go to Login")}
          </.auth_link_button>
        </div>
      </:form>
      <:footer :if={@contact_url}>
        <.auth_footer
          prompt={dgettext("auth", "Need help?")}
          href={@contact_url}
          link_text={dgettext("auth", "Contact Support")}
        />
      </:footer>
    </.auth_card_layout>
    """
  end
end
