defmodule TymeslotWeb.Hooks.LocaleHook do
  @moduledoc """
  LiveView hook to handle locale assignment for scheduling pages.
  Ensures the locale is set in Gettext and socket assigns from either
  URL parameters or the session.
  """

  import Phoenix.Component
  alias Tymeslot.Locales

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, session, socket) do
    # Priority: 1. URL parameter, 2. Session, 3. Default. Each source is
    # validated individually (`Locales.acceptable/1`), matching LocalePlug: an
    # unacceptable candidate (e.g. an unsupported `?locale=` param) falls
    # through to the next source instead of short-circuiting the chain and
    # being coerced to the default.
    locale =
      Locales.acceptable(params["locale"]) ||
        Locales.acceptable(session["locale"]) ||
        Locales.default_locale()

    # Set for Gettext process dictionary (global — reaches every backend)
    Gettext.put_locale(locale)

    # Assign to socket
    {:cont, assign(socket, :locale, locale)}
  end
end
