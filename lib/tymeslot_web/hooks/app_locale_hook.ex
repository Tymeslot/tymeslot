defmodule TymeslotWeb.Hooks.AppLocaleHook do
  @moduledoc """
  LiveView hook that sets the locale for the authenticated app (dashboard,
  account, onboarding, admin).

  Resolution mirrors the HTTP `LocalePlug` running with `prefer_user_locale`:
  a path-derived locale (`"path_locale"` in the live_session's static session
  map, set by locale-prefixed routes such as /de/...) wins outright, then the
  signed-in user's saved interface language, otherwise the session locale
  (which `LocalePlug` populated from the query param / Accept-Language on the
  page load), falling back to the default.

  Must run *after* the auth hook has assigned `:current_user` — it is placed at
  the end of the dashboard hook chain and after the auth hook in the admin and
  onboarding live-sessions.
  """

  import Phoenix.Component
  alias Tymeslot.Locales

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    # Each source is validated individually (`Locales.acceptable/1`), matching
    # LocalePlug: an unacceptable candidate (e.g. a stale, unsupported user
    # preference) falls through to the next source instead of short-circuiting
    # the chain and being coerced to the default.
    locale =
      Locales.acceptable(path_locale(session)) ||
        Locales.acceptable(user_locale(socket)) ||
        Locales.acceptable(session_locale(session)) ||
        Locales.default_locale()

    Gettext.put_locale(locale)

    # The same resolution with the user's saved preference removed from the
    # chain: the locale a remount will resolve to once that preference is
    # cleared (e.g. switching to "Automatic"). UI actions that build
    # user-facing text ahead of such a remount (the language switcher's
    # confirmation flash) read this instead of `:locale` so the flash matches
    # what the page is about to render.
    ambient =
      Locales.acceptable(path_locale(session)) ||
        Locales.acceptable(session_locale(session)) ||
        Locales.default_locale()

    {:cont, assign(socket, locale: locale, ambient_locale: ambient)}
  end

  # The URL is the most explicit statement of intent — locale-prefixed routes
  # inject their locale into the live_session's static session map so it
  # outranks the saved user preference, matching LocalePlug's precedence.
  defp path_locale(%{"path_locale" => locale}) when is_binary(locale), do: locale
  defp path_locale(_session), do: nil

  defp user_locale(socket) do
    case socket.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) -> locale
      _other -> nil
    end
  end

  defp session_locale(%{"locale" => locale}) when is_binary(locale), do: locale
  defp session_locale(_session), do: nil
end
