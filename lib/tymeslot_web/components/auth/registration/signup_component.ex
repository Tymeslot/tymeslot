defmodule TymeslotWeb.Registration.SignupComponent do
  @moduledoc """
  User registration signup component.

  Provides the signup form UI with email/password registration
  and OAuth provider options.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Shared.SocialAuthButtons
  import TymeslotWeb.Shared.PasswordToggleButtonComponent
  import TymeslotWeb.Components.CoreComponents

  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the signup page with animated background and form.
  """
  @spec auth_signup(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_signup(assigns) do
    assigns =
      assigns
      |> Map.put_new(:errors, %{})
      |> Map.put_new(:loading, false)

    ~H"""
    <.auth_card_layout title="Join Tymeslot" subtitle="Start scheduling your meetings with ease. Zero friction, total control.">
      <:form>
        <.auth_form
          id="signup-form"
          phx-submit="submit_signup"
          loading={@loading}
          csrf_token={@csrf_token}
          rest={
            if RecaptchaHelpers.signup_active?() do
              %{
                :"data-site-key" => RecaptchaHelpers.site_key(),
                :"data-recaptcha-action" => "signup_form",
                :"data-recaptcha-event" => "submit_signup",
                :"data-recaptcha-param-root" => "user",
                :"data-recaptcha-require-token" => "true",
                :"phx-hook" => "RecaptchaV3"
              }
            else
              %{}
            end
          }
        >
          <div class="sr-only" aria-hidden="true">
            <label for="signup-website">Website</label>
            <input
              id="signup-website"
              type="text"
              name="user[website]"
              tabindex="-1"
              autocomplete="off"
              value=""
            />
          </div>
          <div class="space-y-4 sm:space-y-5 mb-2">
            <.input
              name="user[email]"
              type="email"
              label="Email Address"
              errors={FormValidationHelpers.field_errors(@errors, :email)}
              value={Map.get(@form_data, :email, "")}
              phx-change="validate_signup"
              phx-debounce="blur"
              icon="hero-envelope"
              required
              autofocus
            />
            <div id="signup-password-toggle-container" data-password-container phx-hook="PasswordToggle">
              <.input
                id="password-input"
                name="user[password]"
                type="password"
                label="Password"
                placeholder="Create a password"
                required
                aria-describedby="password-requirements"
                errors={FormValidationHelpers.field_errors(@errors, :password)}
                icon="hero-lock-closed"
              >
                <:trailing_icon>
                  <.password_toggle_button id="password-toggle" />
                </:trailing_icon>
              </.input>
              <.password_requirements />
            </div>
            <%= if Application.get_env(:tymeslot, :enforce_legal_agreements, false) do %>
              <.terms_checkbox name="user[terms_accepted]" style={:simple} />
            <% end %>
          </div>

          <%= if RecaptchaHelpers.signup_active?() do %>
            <input
              type="hidden"
              name="user[g-recaptcha-response]"
              id="signup-g-recaptcha-response"
              value=""
            />
            <div class="text-xs text-tymeslot-500 text-center mt-3">
              This site is protected by reCAPTCHA and the Google
              <a
                href="https://policies.google.com/privacy"
                target="_blank"
                rel="noopener noreferrer"
                class="text-turquoise-600 underline hover:text-turquoise-700"
              >
                Privacy Policy
              </a>
              and
              <a
                href="https://policies.google.com/terms"
                target="_blank"
                rel="noopener noreferrer"
                class="text-turquoise-600 underline hover:text-turquoise-700"
              >
                Terms of Service
              </a>
              apply.
            </div>
          <% end %>

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
              <.spinner class="-ml-1 mr-3 h-5 w-5 text-white" />
              Signing up...
            <% else %>
              Sign up
            <% end %>
          </.auth_button>
        </.auth_form>
      </:form>
      <:social>
        <.social_auth_buttons />
      </:social>
      <:footer>
        <.auth_footer
          prompt="Already have an account?"
          phx-click="navigate_to"
          phx-value-state="login"
          link_text="Log in"
        />
      </:footer>
    </.auth_card_layout>
    """
  end
end
