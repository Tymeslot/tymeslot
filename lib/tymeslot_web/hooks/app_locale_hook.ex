defmodule TymeslotWeb.Hooks.AppLocaleHook do
  @moduledoc """
  LiveView hook that sets the locale for the authenticated app (dashboard,
  account, onboarding, admin).

  Resolution mirrors `TymeslotWeb.Plugs.LocalePlug` running with
  `prefer_user_locale`: a path-derived locale wins outright, then the
  signed-in user's saved interface language, then whatever the dead render
  detected without it (`"ambient_locale"`: an explicit `?locale=` choice or
  the browser's `Accept-Language`), then the admin surface's fallback. The
  live_session carries the path and ambient locales in from the dead render
  (see `LocalePlug.live_session_data/1`), because the connected mount has no
  request headers. The saved preference is re-read from `:current_user`
  rather than taken from the dead render, so a preference changed after the
  page loaded takes effect on the next remount.

  Must run *after* the auth hook has assigned `:current_user`: it is placed at
  the end of the dashboard hook chain and after the auth hook in the admin and
  onboarding live-sessions.
  """

  import Phoenix.Component
  alias Tymeslot.Locales

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    fallback = Locales.admin_default_locale()
    path_locale = session["path_locale"]
    ambient = Locales.resolve([path_locale, session["ambient_locale"]], fallback)
    locale = Locales.resolve([path_locale, user_locale(socket), ambient], fallback)

    Gettext.put_locale(locale)

    # `ambient` is the locale a remount will resolve to once the user's saved
    # preference is cleared (e.g. switching to "Automatic"). UI actions that
    # build user-facing text ahead of such a remount (the language switcher's
    # confirmation flash) read it instead of `:locale` so the flash matches
    # what the page is about to render.
    {:cont, assign(socket, locale: locale, ambient_locale: ambient)}
  end

  defp user_locale(socket) do
    case socket.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) -> locale
      _other -> nil
    end
  end
end
