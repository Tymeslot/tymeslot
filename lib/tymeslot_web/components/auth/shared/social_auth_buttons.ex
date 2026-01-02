defmodule TymeslotWeb.Shared.SocialAuthButtons do
  @moduledoc """
  Social authentication buttons component for OAuth login/signup flows.

  Provides styled Google and GitHub authentication buttons with consistent
  design and behavior across login and signup forms.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the social authentication buttons section with a divider.
  Only shows buttons for providers that are enabled in the configuration.
  Usage:
    <.social_auth_buttons signup={true} /> # For signup page
    <.social_auth_buttons /> # For login page
  """
  attr :signup, :boolean, default: false
  @spec social_auth_buttons(map()) :: Phoenix.LiveView.Rendered.t()
  def social_auth_buttons(assigns) do
    social_auth_config = Application.get_env(:tymeslot, :social_auth, [])
    google_enabled = Keyword.get(social_auth_config, :google_enabled, false)
    github_enabled = Keyword.get(social_auth_config, :github_enabled, false)
    any_enabled = google_enabled || github_enabled

    assigns =
      assigns
      |> assign(:google_enabled, google_enabled)
      |> assign(:github_enabled, github_enabled)
      |> assign(:any_enabled, any_enabled)
      |> assign(:grid_cols, determine_grid_cols(google_enabled, github_enabled))

    ~H"""
    <div :if={@any_enabled} class="mt-6">
      <div class="auth-divider">
        <span class="auth-divider-text">Or continue with</span>
      </div>

      <div class={"mt-6 grid grid-cols-1 gap-3 #{@grid_cols}"}>
        <.social_auth_button
          :if={@google_enabled}
          provider="google"
          label={if @signup, do: "Sign up with Google", else: "Log in with Google"}
          href="/auth/google"
        />
        <.social_auth_button
          :if={@github_enabled}
          provider="github"
          label={if @signup, do: "Sign up with GitHub", else: "Log in with GitHub"}
          href="/auth/github"
        />
      </div>
    </div>
    """
  end

  defp determine_grid_cols(true, true), do: "sm:grid-cols-2"
  defp determine_grid_cols(_, _), do: ""

  @doc """
  Renders a social authentication button for a given provider.
  Usage:
    <.social_auth_button provider="google" label="Log in with Google" href="/auth/google" />
    <.social_auth_button provider="github" label="Log in with GitHub" href="/auth/github" />
  """
  attr :provider, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :class, :string, default: ""
  @spec social_auth_button(map()) :: Phoenix.LiveView.Rendered.t()
  def social_auth_button(assigns) do
    assigns = assign(assigns, :icon, icon_for(assigns.provider))

    ~H"""
    <a href={@href} class={["btn-oauth", "btn-oauth-#{@provider}", @class]} aria-label={@label}>
      {Phoenix.HTML.raw(@icon)}
      <span>{@label}</span>
    </a>
    """
  end

  defp icon_for("google"),
    do: """
      <svg class=\"w-5 h-5\" viewBox=\"0 0 48 48\"><g><path fill=\"#4285F4\" d=\"M24 9.5c3.54 0 6.44 1.22 8.37 2.62l6.2-6.2C34.62 2.91 29.7 0 24 0 14.82 0 6.96 5.82 3.13 14.09l7.41 5.76C12.4 14.3 17.74 9.5 24 9.5z\"/><path fill=\"#34A853\" d=\"M46.1 24.5c0-1.64-.15-3.21-.43-4.71H24v9.01h12.41c-.53 2.87-2.13 5.29-4.53 6.92l7.2 5.59C43.92 37.34 46.1 31.36 46.1 24.5z\"/><path fill=\"#FBBC05\" d=\"M10.54 28.15A14.5 14.5 0 019.5 24c0-1.44.25-2.83.7-4.15l-7.41-5.76A23.91 23.91 0 000 24c0 3.91.94 7.61 2.59 10.91l7.95-6.23z\"/><path fill=\"#EA4335\" d=\"M24 48c6.48 0 11.92-2.15 15.89-5.85l-7.2-5.59c-2.01 1.36-4.58 2.17-8.69 2.17-6.26 0-11.6-4.8-13.46-11.21l-7.95 6.23C6.96 42.18 14.82 48 24 48z\"/></g></svg>
    """

  defp icon_for("github"),
    do: """
      <svg class=\"w-5 h-5\" fill=\"currentColor\" viewBox=\"0 0 24 24\">
        <path d=\"M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12\" />
      </svg>
    """

  defp icon_for(_), do: ""
end
