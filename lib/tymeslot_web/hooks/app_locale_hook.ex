defmodule TymeslotWeb.Hooks.AppLocaleHook do
  @moduledoc """
  LiveView hook that sets the locale for the authenticated app (dashboard,
  account, onboarding, admin).

  Resolution mirrors the HTTP `LocalePlug` running with `prefer_user_locale`:
  the signed-in user's saved interface language wins when set, otherwise the
  session locale (which `LocalePlug` populated from the query param /
  Accept-Language on the page load), falling back to the default.

  Must run *after* the auth hook has assigned `:current_user` — it is placed at
  the end of the dashboard hook chain and after the auth hook in the admin and
  onboarding live-sessions.
  """

  import Phoenix.Component
  alias TymeslotWeb.Themes.Shared.LocaleHandler

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    locale =
      user_locale(socket) ||
        session_locale(session) ||
        LocaleHandler.default_locale()

    locale =
      if locale in LocaleHandler.supported_locales(),
        do: locale,
        else: LocaleHandler.default_locale()

    Gettext.put_locale(TymeslotWeb.Gettext, locale)

    {:cont, assign(socket, :locale, locale)}
  end

  defp user_locale(socket) do
    case socket.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) -> locale
      _other -> nil
    end
  end

  defp session_locale(%{"locale" => locale}) when is_binary(locale), do: locale
  defp session_locale(_session), do: nil
end
