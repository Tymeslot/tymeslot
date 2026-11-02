defmodule TymeslotWeb.Themes.Paper.Components do
  @moduledoc """
  The pieces Paper's steps and pages share: the card's brand row with the
  organiser's logo, the organiser's avatar, and a meeting fact (an icon
  beside a line of text, one `li` of a `ul.paper-facts`, or a `span` in a
  meeting type's row on the overview).

  The logo is the page's tokens' `media[:logo]`, which `Options.Logo`
  resolves and sanitises, so a step draws it without reading the
  customisation. Paper shows it top-left of every card when the organiser
  has uploaded one; the overview then leaves out the avatar its
  introduction otherwise opens with.
  """
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.Demo
  alias Tymeslot.ThemeCustomizations.Tokens

  @doc "The organiser's logo (`%{src: url}`), or nil when they have none."
  @spec logo(Tokens.t() | nil) :: %{src: String.t()} | nil
  def logo(%Tokens{media: media}), do: media[:logo]
  def logo(_no_tokens), do: nil

  attr :theme_tokens, :any, default: nil, doc: "the page's `%Tokens{}`, or nil"

  @doc "The card's brand row: the organiser's logo, or nothing at all without one."
  @spec brand(map()) :: Phoenix.LiveView.Rendered.t()
  def brand(assigns) do
    assigns = assign(assigns, :logo, logo(assigns.theme_tokens))

    ~H"""
    <div :if={@logo} class="paper-brand">
      <img src={@logo.src} alt="" class="paper-logo" data-testid="theme-logo" />
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :size, :atom, values: [:sm, :lg], default: :sm

  @doc "The organiser's avatar, small (beside the meeting's details) or large (the overview)."
  @spec avatar(map()) :: Phoenix.LiveView.Rendered.t()
  def avatar(assigns) do
    ~H"""
    <img
      src={Demo.avatar_url(@profile, :thumb)}
      alt={Demo.avatar_alt_text(@profile)}
      class={["paper-avatar", "paper-avatar--#{@size}"]}
    />
    """
  end

  attr :icon, :string, required: true, doc: "a `hero-*` icon name"

  attr :tag, :string,
    values: ["li", "span"],
    default: "li",
    doc: "`li` in a `ul.paper-facts`; `span` inside a button, which holds no list"

  attr :rest, :global
  slot :inner_block, required: true

  @doc "One meeting fact: an icon beside its text."
  @spec fact(map()) :: Phoenix.LiveView.Rendered.t()
  def fact(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag} class="paper-fact" {@rest}>
      <.icon name={@icon} class="paper-fact__icon" />
      <span class="paper-fact__text">{render_slot(@inner_block)}</span>
    </.dynamic_tag>
    """
  end
end
