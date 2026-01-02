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
  import TymeslotWeb.Shared.Auth.InputComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents

  @doc """
  Renders the login page with animated background and form.

  ## Assigns
  - `:app_name` (required): The name of the application to display in the login title.
  - `:flash` (optional): A map of flash messages to display.
  """
  @spec auth_login(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_login(assigns) do
    # Initialize flash as empty map if not provided
    assigns =
      assigns
      |> Map.put_new(:flash, %{})
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:loading, false)
      |> Map.put_new(:form_data, %{})

    ~H"""
    <.auth_card_layout title="Welcome Back!">
      <:heading>
        <h2 class="text-fluid-sm sm:text-fluid-md md:text-fluid-lg font-bold text-primary-600 mb-6 sm:mb-8 font-heading tracking-tight text-center sm:text-left">
          Log in to {@app_name}
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
            <.standard_email_input
              name="email"
              value={Map.get(@form_data, :email, "")}
              errors={Map.get(@errors, :email, [])}
              phx-change="validate_login"
            />
            <div>
              <.form_label for="password-input" text="Password" />
              <.auth_text_input
                id="password-input"
                name="password"
                type="password"
                placeholder="Enter your password"
                required={true}
                value={Map.get(@form_data, :password, "")}
                errors={Map.get(@errors, :password, [])}
              >
                <.password_toggle_button id="password-toggle" />
              </.auth_text_input>
            </div>
            <div class="text-fluid-xs sm:text-fluid-sm mt-1 mb-2">
              <button
                type="button"
                phx-click="navigate_to"
                phx-value-state="reset_password"
                class="font-medium text-primary-600 hover:text-primary-700 transition duration-300 ease-in-out border-none bg-transparent cursor-pointer"
              >
                Forgot password?
              </button>
            </div>
          </div>

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
        <.auth_footer
          prompt="Don't have an account?"
          phx-click="navigate_to"
          phx-value-state="signup"
          link_text="Sign up"
        />
      </:footer>
    </.auth_card_layout>
    """
  end
end
