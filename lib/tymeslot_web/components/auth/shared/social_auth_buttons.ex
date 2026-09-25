defmodule TymeslotWeb.Shared.SocialAuthButtons do
  @moduledoc """
  Social authentication buttons component for OAuth login/signup flows.

  Provides styled buttons for each enabled sign-in provider, consistent
  across the login and signup forms.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Auth.OAuth.Providers
  alias TymeslotWeb.Components.Icons.ProviderIcon

  @doc """
  Renders the social authentication buttons section with a divider.
  Only shows buttons for the providers an admin has switched on.
  Usage:
    <.social_auth_buttons /> # For signup or login page
  """
  @spec social_auth_buttons(map()) :: Phoenix.LiveView.Rendered.t()
  def social_auth_buttons(assigns) do
    providers = Providers.enabled()

    assigns =
      assign(assigns, providers: providers, grid_cols: determine_grid_cols(length(providers)))

    ~H"""
    <div :if={@providers != []} class="space-y-4">
      <div class={"grid grid-cols-1 gap-4 #{@grid_cols}"}>
        <.social_auth_button
          :for={provider <- @providers}
          provider={provider.slug}
          label={provider.name}
          href={~p"/auth/#{provider.slug}"}
        />
      </div>
    </div>
    """
  end

  defp determine_grid_cols(3), do: "sm:grid-cols-3"
  defp determine_grid_cols(2), do: "sm:grid-cols-2"
  defp determine_grid_cols(_count), do: ""

  attr :provider, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :class, :string, default: ""
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]

  @spec social_auth_button(map()) :: Phoenix.LiveView.Rendered.t()
  defp social_auth_button(assigns) do
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
