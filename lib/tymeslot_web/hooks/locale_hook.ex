defmodule TymeslotWeb.Hooks.LocaleHook do
  @moduledoc """
  LiveView hook that sets the locale for public pages: booking, meeting
  management, polls, payment return, and the auth pages.

  The connected mount has no conn and no request headers, so it reuses what
  `TymeslotWeb.Plugs.LocalePlug` resolved on the dead render, which the
  live_session carries in as `"resolved_locale"` (see
  `LocalePlug.live_session_data/1`). A `?locale=` param on the mount URL still
  wins, so a locale switch applied by patching the URL is honoured.
  """

  import Phoenix.Component
  alias Tymeslot.Locales

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, session, socket) do
    locale =
      Locales.resolve(
        [params["locale"], session["resolved_locale"]],
        Locales.booking_default_locale()
      )

    # Global: reaches every Gettext backend in this process, not just Core's.
    Gettext.put_locale(locale)

    {:cont, assign(socket, :locale, locale)}
  end
end
