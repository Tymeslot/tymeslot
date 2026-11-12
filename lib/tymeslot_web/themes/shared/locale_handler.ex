defmodule TymeslotWeb.Themes.Shared.LocaleHandler do
  @moduledoc """
  Shared locale handling for scheduling LiveViews.
  Provides functions for managing locale in LiveView context.

  Locale configuration (default locale, supported set) is owned by
  `Tymeslot.Locales` — this module only handles the LiveView-socket concern
  of applying a locale to the current process and socket assigns.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.ContentTranslations.Languages

  @doc """
  Applies a `?locale=` found in `handle_params/3` to the running LiveView,
  when it is acceptable and the organiser offers it
  (`Tymeslot.ContentTranslations.Languages.offers?/2`); otherwise leaves the
  socket untouched, so a locale the organiser does not offer keeps the page
  in the language it was mounted in.

  On a page that shows an organiser's texts (`:organizer_profile` assigned)
  and given the page's `url`, a change of language reloads the page instead:
  those texts were put into the page's language when it mounted, so only a
  fresh mount shows them in the new one. The reload also lets
  `TymeslotWeb.Plugs.LocalePlug` remember the choice in the session, exactly
  as the language switcher's `change_locale` event does
  (`EventHandlers.handle_change_locale/3`). Pages without organiser texts,
  and calls without a `url`, switch in place. The caller stops handling the
  params once the socket is redirected.
  """
  @spec handle_locale_change(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def handle_locale_change(socket, new_locale, url \\ nil) do
    profile = socket.assigns[:organizer_profile]

    cond do
      not Languages.offers?(profile, new_locale) ->
        socket

      # The language already shown never reloads, so the reloaded page,
      # whose URL still carries `?locale=`, cannot loop.
      new_locale != socket.assigns[:locale] and is_binary(url) and profile != nil ->
        LiveView.redirect(socket, external: url)

      true ->
        Gettext.put_locale(new_locale)
        Component.assign(socket, :locale, new_locale)
    end
  end
end
