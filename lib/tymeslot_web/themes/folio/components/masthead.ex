defmodule TymeslotWeb.Themes.Folio.Components.Masthead do
  @moduledoc """
  The top of Folio's pages: the cover band, and the organiser's portrait
  overlapping its lower edge with their name beside or below it.

  `:full` (the booking page and its confirmation) has the tall band, the
  large portrait, the name as the page's `h1`, and the headline and bio (the
  shared `ProfileIntro`); `:slim` has a short band, a small portrait and the
  name as text. Without an organiser profile (the meeting, poll and payment
  pages) only the band is drawn.

  The cover is the tokens' `media[:cover]`; its crop per preset is CSS
  (`.folio-cover[data-cover="<id>"]` in `masthead.css`). With no cover, the
  band is a tint of the palette.
  """
  use Phoenix.Component

  alias Tymeslot.Demo
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.Components.ProfileIntro

  attr :variant, :atom, values: [:full, :slim], default: :slim
  attr :theme_tokens, :any, default: nil, doc: "the page's `%Tokens{}`, or nil"
  attr :organizer_profile, :map, default: nil
  attr :username_context, :string, default: nil

  @spec masthead(map()) :: Phoenix.LiveView.Rendered.t()
  def masthead(assigns) do
    assigns =
      assign(assigns,
        cover: cover_media(assigns.theme_tokens),
        name: name(assigns.organizer_profile, assigns.username_context)
      )

    ~H"""
    <header class={["folio-masthead", "folio-masthead--#{@variant}"]}>
      <div
        class={["folio-cover", @variant == :slim && "folio-cover--slim"]}
        data-cover={@cover && (@cover.preset || "custom")}
        data-testid="folio-cover"
      >
        <img
          :if={@cover}
          class="folio-cover__image"
          src={@cover.src}
          alt=""
          decoding="async"
          fetchpriority={if @variant == :full, do: "high", else: "auto"}
        />
      </div>
      <div :if={@organizer_profile} class="folio-identity">
        <img
          class="folio-portrait"
          src={Demo.avatar_url(@organizer_profile, :original)}
          alt={Demo.avatar_alt_text(@organizer_profile)}
        />
        <div class="folio-identity__text">
          <%= if @variant == :full do %>
            <h1 class="folio-identity__name">{@name}</h1>
            <ProfileIntro.headline profile={@organizer_profile} />
          <% else %>
            <p class="folio-identity__name">{@name}</p>
          <% end %>
        </div>
        <ProfileIntro.bio
          :if={@variant == :full}
          profile={@organizer_profile}
          class="folio-identity__bio"
        />
      </div>
    </header>
    """
  end

  defp cover_media(%Tokens{media: media}), do: media[:cover]
  defp cover_media(_no_tokens), do: nil

  defp name(nil, username), do: username
  defp name(profile, username), do: Profiles.display_name(profile) || username
end
