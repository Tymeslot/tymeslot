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
  Applies the URL's `?locale=` (`new_locale`, nil when absent) in
  `handle_params/3`, when it is acceptable and the organiser offers it
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
  and calls without a `url`, switch in place.

  A page whose own URL asked for a language the organiser does not offer
  (`:stale_locale_param`, assigned by
  `TymeslotWeb.Live.Scheduling.OrganizerHelpers.assign_page_language/3`) is
  shown in the original, and reloads with `?locale=` naming it, so the
  address says the language the page is in. A remembered pick the organiser
  does not offer never reloads: the page is simply shown in the original.

  Returns `{:reload, socket}` when the socket now redirects, and the caller
  stops handling the params; `{:cont, socket}` otherwise.
  """
  @spec handle_locale_change(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t() | nil) ::
          {:cont | :reload, Phoenix.LiveView.Socket.t()}
  def handle_locale_change(socket, new_locale, url \\ nil) do
    profile = socket.assigns[:organizer_profile]
    reloadable? = is_binary(url) and profile != nil

    cond do
      reloadable? and socket.assigns[:stale_locale_param] == true ->
        {:reload, reload(socket, url, socket.assigns.locale)}

      not Languages.offers?(profile, new_locale) ->
        {:cont, socket}

      # The language already shown never reloads, so the reloaded page,
      # whose URL still carries `?locale=`, cannot loop.
      reloadable? and new_locale != socket.assigns[:locale] ->
        {:reload, LiveView.redirect(socket, external: url)}

      true ->
        Gettext.put_locale(new_locale)
        {:cont, Component.assign(socket, :locale, new_locale)}
    end
  end

  @doc """
  `url` with its `?locale=` set to `locale`, every other parameter kept.
  """
  @spec with_locale(String.t(), String.t()) :: String.t()
  def with_locale(url, locale) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    URI.to_string(%{uri | query: URI.encode_query(Map.put(query, "locale", locale))})
  end

  defp reload(socket, url, locale),
    do: LiveView.redirect(socket, external: with_locale(url, locale))
end
