defmodule TymeslotWeb.Session.LoginComponent do
  @moduledoc """
  User login component.

  Provides the login form UI with email/password authentication
  and OAuth provider options.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.SocialAuthButtons
  import TymeslotWeb.Shared.PasswordToggleButtonComponent
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Components.CoreComponents
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the login page with animated background and form.

  ## Assigns
  - `:flash` (optional): A map of flash messages to display.
  """
  @spec auth_login(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_login(assigns) do
    assigns =
      assigns
      |> Map.put_new(:flash, %{})
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:loading, false)
      |> Map.put_new(:form_data, %{})
      |> Map.put_new(:password_auth_enabled, Config.password_auth_enabled?())
      |> Map.put_new(:registration_enabled, Config.registration_enabled?())

    ~H"""
    <%= if @password_auth_enabled do %>
      <.auth_card_layout title="Welcome Back!">
        <:heading>
          <h2 class="text-xl font-bold text-tymeslot-900 mb-6 tracking-tight text-center">
            Log in to Tymeslot
          </h2>
        </:heading>

        <:form>
          <.auth_form
            id="login-form"
            action="/auth/session"
            method="POST"
            loading={@loading}
            csrf_token={@csrf_token}
          >
            <div class="space-y-4 sm:space-y-5">
              <.input
                name="email"
                type="email"
                label="Email Address"
                value={Map.get(@form_data, :email, "")}
                errors={FormValidationHelpers.field_errors(@errors, :email)}
                phx-blur="validate_login_email"
                icon="hero-envelope"
                required
                autofocus
              />
              <div id="login-password-toggle-container" phx-hook="PasswordToggle" data-password-container>
                <.input
                  id="password-input"
                  name="password"
                  type="password"
                  label="Password"
                  placeholder="Enter your password"
                  required
                  value={Map.get(@form_data, :password, "")}
                  errors={FormValidationHelpers.field_errors(@errors, :password)}
                  icon="hero-lock-closed"
                >
                  <:trailing_icon>
                    <.password_toggle_button id="password-toggle" />
                  </:trailing_icon>
                </.input>
              </div>
              <div class="text-xs sm:text-sm mt-1 mb-2 text-center">
                <button
                  type="button"
                  phx-click="navigate_to"
                  phx-value-state="reset_password"
                  class="btn-link bg-transparent"
                >
                  Forgot password?
                </button>
              </div>
            </div>

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
                Logging in...
              <% else %>
                Log in
              <% end %>
            </.auth_button>
          </.auth_form>
        </:form>
        <:social>
          <.social_auth_buttons />
        </:social>
        <:footer>
          <%= if @registration_enabled do %>
            <.auth_footer
              prompt="Don't have an account?"
              phx-click="navigate_to"
              phx-value-state="signup"
              link_text="Sign up"
            />
          <% end %>
        </:footer>
      </.auth_card_layout>
    <% else %>
      <.auth_card_layout title="Welcome Back!">
        <:heading>
          <h2 class="text-xl font-bold text-tymeslot-900 mb-6 tracking-tight text-center">
            Log in to Tymeslot
          </h2>
        </:heading>

        <:form>
          <.social_auth_buttons />
        </:form>
      </.auth_card_layout>
    <% end %>
    """
  end
end
