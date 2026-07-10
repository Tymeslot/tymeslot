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
    # Priority: 1. URL parameter, 2. Session, 3. Default
    locale =
      params["locale"] ||
        session["locale"] ||
        Locales.default_locale()

    # Validate locale is supported (or the dev-only pseudo locale)
    locale =
      if Locales.acceptable?(locale),
        do: locale,
        else: Locales.default_locale()

    # Set for Gettext process dictionary (global — reaches every backend)
    Gettext.put_locale(locale)

    # Assign to socket
    {:cont, assign(socket, :locale, locale)}
  end
end
