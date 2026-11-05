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

  `post_prefix` points the buttons at another flow that starts a social
  sign-in: each becomes a CSRF-protected form POSTed to
  `<prefix>/<provider slug>`, for a flow another site must not be able to
  start on the visitor's behalf.
  """
  attr :post_prefix, :string, default: nil, doc: "POSTs each button's flow to this path"

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
          href={provider_href(@post_prefix, provider.slug)}
          post={@post_prefix != nil}
        />
      </div>
    </div>
    """
  end

  defp provider_href(nil, slug), do: ~p"/auth/#{slug}"
  defp provider_href(prefix, slug), do: prefix <> "/" <> slug

  defp determine_grid_cols(3), do: "sm:grid-cols-3"
  defp determine_grid_cols(2), do: "sm:grid-cols-2"
  defp determine_grid_cols(_count), do: ""

  attr :provider, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :post, :boolean, default: false, doc: "A form POSTed to href, rather than a link"
  attr :class, :string, default: ""
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]

  @spec social_auth_button(map()) :: Phoenix.LiveView.Rendered.t()
  defp social_auth_button(%{post: true} = assigns) do
    ~H"""
    <form method="post" action={@href}>
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <button
        type="submit"
        class={["btn-oauth", "btn-oauth-#{@provider}", "w-full", @class]}
        aria-label={@label}
        data-tymeslot-suppress-lv-disconnect="oauth"
      >
        <div class="w-6 h-6">
          <ProviderIcon.provider_icon provider={@provider} type="oauth" size={@icon_size} />
        </div>
        <span>{@label}</span>
      </button>
    </form>
    """
  end

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
