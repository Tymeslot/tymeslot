defmodule TymeslotWeb.Themes.Shared.LocaleHandler do
  @moduledoc """
  Shared locale handling for scheduling LiveViews.
  Provides functions for managing locale in LiveView context.

  Locale configuration (default locale, supported set) is owned by
  `Tymeslot.Locales` — this module only handles the LiveView-socket concern
  of applying a locale to the current process and socket assigns.
  """

  alias Phoenix.Component
  alias Tymeslot.Locales

  @doc """
  Applies `new_locale` to the current process and the socket's `:locale`
  assign, when it is acceptable; otherwise leaves both untouched.

  Called from `handle_params/3` when the URL carries `?locale=`. It only
  affects the running LiveView. The language switcher does not go through
  here: its `change_locale` event does a full `redirect(external: ...)` to the
  same page with `?locale=` (see `EventHandlers.handle_change_locale/3`), so
  that `TymeslotWeb.Plugs.LocalePlug` sees the request and remembers the
  choice in the session, which a websocket message cannot do.
  """
  @spec handle_locale_change(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_locale_change(socket, new_locale) do
    if Locales.acceptable?(new_locale) do
      Gettext.put_locale(new_locale)
      Component.assign(socket, :locale, new_locale)
    else
      socket
    end
  end
end
