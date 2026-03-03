defmodule TymeslotWeb.Shared.SocialAuthButtons do
  @moduledoc """
  Social authentication buttons component for OAuth login/signup flows.

  Provides styled Google and GitHub authentication buttons with consistent
  design and behavior across login and signup forms.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.ProviderIcon

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
    oauth_enabled = Keyword.get(social_auth_config, :oauth_enabled, false)
    any_enabled = google_enabled || github_enabled || oauth_enabled

    enabled_count =
      Enum.count([google_enabled, github_enabled, oauth_enabled], & &1)

    assigns =
      assigns
      |> assign(:google_enabled, google_enabled)
      |> assign(:github_enabled, github_enabled)
      |> assign(:oauth_enabled, oauth_enabled)
      |> assign(:any_enabled, any_enabled)
      |> assign(:grid_cols, determine_grid_cols(enabled_count))

    ~H"""
    <div :if={@any_enabled} class="space-y-4">
      <div class={"grid grid-cols-1 gap-4 #{@grid_cols}"}>
        <.social_auth_button
          :if={@google_enabled}
          provider="google"
          label={if @signup, do: "Join with Google", else: "Google"}
          href={~p"/auth/google"}
        />
        <.social_auth_button
          :if={@github_enabled}
          provider="github"
          label={if @signup, do: "Join with GitHub", else: "GitHub"}
          href={~p"/auth/github"}
        />
        <.social_auth_button
          :if={@oauth_enabled}
          provider="oauth"
          label={if @signup, do: "Join with SSO", else: "SSO"}
          href={~p"/auth/oauth"}
        />
      </div>
    </div>
    """
  end

  defp determine_grid_cols(3), do: "sm:grid-cols-3"
  defp determine_grid_cols(2), do: "sm:grid-cols-2"
  defp determine_grid_cols(_count), do: ""

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
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]

  @spec social_auth_button(map()) :: Phoenix.LiveView.Rendered.t()
  def social_auth_button(assigns) do
    ~H"""
    <a
      href={@href}
      class={["btn-oauth", "btn-oauth-#{@provider}", @class]}
      aria-label={@label}
      data-tymeslot-suppress-lv-disconnect="oauth"
    >
      <div class="w-6 h-6">
        <ProviderIcon.provider_icon provider={@provider} type="oauth" size={@icon_size} />
      </div>
      <span>{@label}</span>
    </a>
    """
  end
end
