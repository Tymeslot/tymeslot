defmodule TymeslotWeb.Plugs.LocalePlug do
  @moduledoc """
  Resolves the request locale, applies it to Gettext, and assigns it.

  Sources, highest priority first; `Tymeslot.Locales.resolve/2` takes the
  first acceptable one:

  1. Path-derived locale (`:path_locale` assign), set as a route assign by
     routers that serve locale-prefixed URLs (`/de/...`)
  2. The signed-in user's saved interface language (only with
     `prefer_user_locale: true`)
  3. The `?locale=` query parameter: an explicit choice
  4. An explicit choice remembered in the session from an earlier request
  5. The `Accept-Language` header, highest weight first
  6. The surface's fallback (`:surface` below)

  ## What the session remembers

  Only an explicit choice. An acceptable `?locale=` parameter is written to
  the session (under `:chosen_locale`), and nothing else ever is: the user
  preference, the header and the fallback are derived afresh on every
  request. Persisting a derived locale would let one surface's fallback leak
  into another in the same session (the admin default rendering a public
  booking page), pin the session to whatever browser language it started
  with, and stop an admin's change to a fallback reaching existing sessions.

  A path-derived locale is not persisted either. The URL restates it on every
  request, so remembering it adds nothing for that URL, and it would silently
  re-language every unprefixed page a visitor reaches after landing on a
  single localised link.

  The session key used to be `:locale`, which held derived values as well.
  That key is no longer read, so a derived locale stored before this change
  cannot outlive it as if it had been chosen.

  ## Assigns

    * `:locale` - the resolved locale.
    * `:ambient_locale` - the same resolution without the user's saved
      preference (source 2): what the page resolves to once that preference
      is cleared. Equal to `:locale` unless `prefer_user_locale` is set.

  A connected LiveView mounts in its own process from a websocket, with no
  conn and no request headers. `live_session_data/1` carries these assigns to
  it through the live_session's signed static session, so the LiveView locale
  hooks reuse what the dead render resolved rather than re-deriving it.

  ## Options

    * `:prefer_user_locale` - consult the signed-in user's saved interface
      language (source 2). Off by default, so public booking pages never
      render in the language of whoever happens to be logged in.
    * `:surface` - which admin-editable fallback ends the chain, `:admin` or
      `:booking`. Defaults to `:booking`: the plug is mounted on public
      pipelines as well as the authenticated one, and a public visitor
      getting the booking fallback is the safe way to be wrong.
    * `:session` - read and remember the explicit choice in the session
      (source 4). Defaults to `true`; pass `false` on pipelines that do not
      fetch the session, such as pages only ever rendered in a cross-site
      iframe, where the browser withholds the session cookie anyway.

  ## Input handling

  Every candidate is whitelisted against the supported locale codes by
  `Tymeslot.Locales.resolve/2`, so nothing reaches Gettext unless it is a
  known code. Normalisation therefore only has to let legitimate spellings
  match: trim, lowercase, and reduce a language-region tag to its primary
  language subtag (`de-AT` becomes `de`); regional locales are out of scope.
  Raw input is length-capped before any work is done on it.
  """
  alias Tymeslot.Locales
  import Plug.Conn
  require Logger

  @session_key :chosen_locale

  # Generous for any real language tag (BCP 47 tags in the wild stay well
  # under this); anything longer is rejected before it is normalised.
  @max_locale_length 35
  @max_header_length 1000
  @max_tags_count 20

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    session? = Keyword.get(opts, :session, true)
    choice = conn.params["locale"] |> normalize_locale() |> Locales.acceptable()
    conn = if session? and choice, do: put_session(conn, @session_key, choice), else: conn

    path_locale = normalize_locale(conn.assigns[:path_locale])
    detected = [choice, remembered_choice(conn, session?) | header_locales(conn)]
    fallback = surface_default(opts)

    locale = Locales.resolve([path_locale, user_locale(conn, opts) | detected], fallback)
    ambient_locale = Locales.resolve([path_locale | detected], fallback)

    # Global: reaches every Gettext backend in this process, not just Core's.
    Gettext.put_locale(locale)

    merge_assigns(conn, locale: locale, ambient_locale: ambient_locale)
  end

  @doc """
  The resolved locales for a LiveView's signed static session.

  Use as (or merge into) a live_session's `session:` so the connected mount
  sees exactly what the dead render resolved, including a locale that came
  from `Accept-Language` alone, which the websocket cannot see:

      live_session :name, session: {TymeslotWeb.Plugs.LocalePlug, :live_session_data, []}

  `TymeslotWeb.Hooks.LocaleHook` reads `"resolved_locale"`;
  `TymeslotWeb.Hooks.AppLocaleHook` reads `"path_locale"` and
  `"ambient_locale"` and re-applies the user's saved preference itself, so a
  preference changed after the page loaded still takes effect on a live
  remount. Absent assigns are left out.
  """
  @spec live_session_data(Plug.Conn.t()) :: %{optional(String.t()) => String.t()}
  def live_session_data(conn) do
    Map.reject(
      %{
        "resolved_locale" => conn.assigns[:locale],
        "ambient_locale" => conn.assigns[:ambient_locale],
        "path_locale" => conn.assigns[:path_locale]
      },
      fn {_key, value} -> is_nil(value) end
    )
  end

  # The end of the chain: the admin-editable fallback for the surface this
  # pipeline serves. Reached only when no source above yielded a supported
  # locale, so setting it never overrides a visitor's actual preference.
  defp surface_default(opts) do
    case Keyword.get(opts, :surface, :booking) do
      :admin -> Locales.admin_default_locale()
      _booking -> Locales.booking_default_locale()
    end
  end

  # Only consulted on pipelines that pass `prefer_user_locale: true` (the
  # authenticated app), never on public booking pages. Requires
  # `FetchCurrentUser` to have run earlier in the pipeline.
  defp user_locale(conn, opts) do
    with true <- Keyword.get(opts, :prefer_user_locale, false),
         %{locale: locale} <- conn.assigns[:current_user] do
      normalize_locale(locale)
    else
      _no_preference -> nil
    end
  end

  defp remembered_choice(conn, true), do: get_session(conn, @session_key)
  defp remembered_choice(_conn, false), do: nil

  # The header's languages, highest weight first. Ties keep header order.
  defp header_locales(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _rest] -> parse_accept_language(header)
      [] -> []
    end
  end

  defp parse_accept_language(header) do
    if byte_size(header) <= @max_header_length and String.valid?(header) do
      header
      |> String.split(",")
      |> Enum.take(@max_tags_count)
      |> Enum.flat_map(&parse_language_range/1)
      |> Enum.sort_by(fn {_locale, weight} -> weight end, :desc)
      |> Enum.map(fn {locale, _weight} -> locale end)
    else
      Logger.warning("Invalid or oversized Accept-Language header",
        valid_utf8: String.valid?(header),
        size: byte_size(header)
      )

      []
    end
  end

  # RFC 9110: `language-range weight`, where
  # `weight = OWS ";" OWS "q=" qvalue`. A weight of 0 means "not acceptable",
  # so such a range is dropped rather than ranked last.
  defp parse_language_range(range) do
    case range |> String.split(";") |> Enum.map(&String.trim/1) do
      [tag] -> weighted(tag, 1.0)
      [tag, weight] -> weighted(tag, parse_qvalue(weight))
      _malformed -> []
    end
  end

  defp weighted(tag, weight) when is_float(weight) and weight > 0.0 do
    case normalize_locale(tag) do
      nil -> []
      locale -> [{locale, weight}]
    end
  end

  defp weighted(_tag, _weight), do: []

  # The "q" is case-insensitive; the qvalue must lie in 0..1.
  defp parse_qvalue(<<q, "=", value::binary>>) when q in [?q, ?Q] do
    case Float.parse(value) do
      {weight, ""} when weight >= 0.0 and weight <= 1.0 -> weight
      _invalid -> nil
    end
  end

  defp parse_qvalue(_weight), do: nil

  # Reduces a tag to its lowercased primary language subtag (`de-AT` and
  # `DE_at` both become `de`). Not a validator: `Locales.resolve/2`
  # whitelists the result against the supported codes.
  defp normalize_locale(input) when is_binary(input) and byte_size(input) <= @max_locale_length do
    if String.valid?(input) do
      input
      |> String.trim()
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> hd()
    end
  end

  defp normalize_locale(_input), do: nil
end
