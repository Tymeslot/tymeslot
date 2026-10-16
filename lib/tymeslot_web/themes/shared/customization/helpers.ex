defmodule TymeslotWeb.Themes.Shared.Customization.Helpers do
  @moduledoc """
  Helper functions for applying theme customizations to booking pages.
  """
  use Phoenix.Component

  alias Tymeslot.Demo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal

  @doc """
  Assigns `:theme_tokens` to a socket: the `%Tokens{}` the theme's spec builds
  from the organiser's customisation, or from the theme's defaults when the
  organiser has none, plus the page view's `:theme_overrides` (an embed's
  `?primary-color=`) when the context assigned any.
  """
  @spec assign_theme_customization(Phoenix.LiveView.Socket.t(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_customization(socket, profile, theme_id) do
    customization = Demo.get_theme_customization(profile.id, theme_id)
    overrides = socket.assigns[:theme_overrides] || %{}

    assign(socket, :theme_tokens, ThemeCustomizations.tokens(theme_id, customization, overrides))
  end

  @doc """
  Prepares common wrapper assigns for theme wrapper components.

  Derives `@background` (the tokens' `media[:background]`, the background
  descriptor, or nil), `@has_video_background` and `@show_language_switcher`
  so each theme wrapper doesn't duplicate this logic; wrappers never read the
  tokens' media themselves.

  `@show_language_switcher` is the wrapper's own choice when it passes one,
  else true on the journey's first moment (the classic overview) and on every
  moment and outcome of a `Continuous` or `Transcript` page but the payment
  wait.
  """
  @spec prepare_wrapper_assigns(map()) :: map()
  def prepare_wrapper_assigns(assigns) do
    background = background(assigns[:theme_tokens])

    show_language_switcher =
      if is_boolean(assigns[:show_language_switcher]),
        do: assigns[:show_language_switcher],
        else: language_switcher?(assigns[:journey], assigns[:current_state])

    assigns
    |> assign(:background, background)
    |> assign(:has_video_background, match?(%{kind: :video}, background))
    |> assign(:show_language_switcher, show_language_switcher)
  end

  # A page that opens its moments by itself is one page, so the switcher is
  # on it throughout, bar the payment wait: a locale change remounts the page
  # on its entry route, which would drop the wait for the checkout. A paged
  # journey shows it on its first moment (the classic overview). A page with
  # no journey keeps the overview rule. The journey is matched as a map, not
  # as `%Journey{}`: a struct pattern would make every wrapper that imports
  # this module depend on the journey engine at compile time.
  defp language_switcher?(journey, current_state) do
    if Reveal.journey?(journey),
      do: current_state != :awaiting_payment,
      else: first_moment?(journey, current_state)
  end

  defp first_moment?(%{moments: [%{key: first} | _rest]}, current_state),
    do: current_state == first

  defp first_moment?(_no_journey, current_state), do: current_state == :overview

  defp background(%Tokens{media: media}), do: media[:background]
  defp background(_no_tokens), do: nil
end
