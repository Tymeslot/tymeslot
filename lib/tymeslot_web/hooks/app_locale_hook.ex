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
    locale =
      path_locale(session) ||
        user_locale(socket) ||
        session_locale(session) ||
        Locales.default_locale()

    locale =
      if Locales.acceptable?(locale),
        do: locale,
        else: Locales.default_locale()

    Gettext.put_locale(locale)

    {:cont, assign(socket, :locale, locale)}
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
