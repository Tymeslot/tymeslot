defmodule Tymeslot.Locales do
  @moduledoc """
  Shared locale utilities for the core domain layer.

  Provides access to locale configuration without coupling domain modules
  to the web layer's LocaleHandler.
  """

  # The development-only pseudo-localisation locale. It is deliberately absent
  # from the `:supported` list so it never appears in a language picker; it is
  # only ever *accepted* by the locale resolver when `pseudo_enabled?/0` is true
  # (dev). See `TymeslotWeb.Gettext.Pseudo`.
  @pseudo_code "pseudo"

  @doc """
  Returns the configured default locale code, falling back to "en".

  This is the instance-wide default: the source language translations are
  written against, and the locale the URL structure treats as unprefixed. Use
  `admin_default_locale/0` or `booking_default_locale/0` at request- and
  recipient-facing resolution points instead, so an admin can set a fallback
  per surface without moving the structural default.
  """
  @spec default_locale() :: String.t()
  def default_locale do
    Application.get_env(:tymeslot, :locales, [])[:default] || "en"
  end

  @doc """
  The locale the authenticated app falls back to: dashboard, account,
  onboarding, admin, and the account mail addressed to a registered user.

  Only the *fallback*: detection still wins. A signed-in user's saved
  language, a locale-prefixed path, and the browser's `Accept-Language` all
  outrank this; it is what resolves when none of them yield a supported
  locale. Unset (the default) means the instance-wide `default_locale/0`.
  """
  @spec admin_default_locale() :: String.t()
  def admin_default_locale, do: surface_default(:admin_default_locale)

  @doc """
  The locale public booking pages fall back to, along with the booking mail and
  calendar invites addressed to an attendee whose language is unknown.

  Only the *fallback*: a visitor's `Accept-Language` and an explicit
  `?locale=` still win. Unset (the default) means the instance-wide
  `default_locale/0`.
  """
  @spec booking_default_locale() :: String.t()
  def booking_default_locale, do: surface_default(:booking_default_locale)

  # A surface default is admin-editable (`Tymeslot.AppSettings` projects the DB
  # override onto this key), so it can outlive the locale it names: dropping a
  # language from `:supported` leaves any install that had selected it holding
  # a code nothing can render. Validate on read rather than trusting the stored
  # value, so a stale override degrades to the instance default instead of
  # rendering untranslated msgids.
  defp surface_default(key) do
    case Application.get_env(:tymeslot, key) do
      code when is_binary(code) -> if acceptable?(code), do: code, else: default_locale()
      _unset -> default_locale()
    end
  end

  @doc """
  Returns the pseudo-localisation locale code (`"pseudo"`).
  """
  @spec pseudo_locale() :: String.t()
  def pseudo_locale, do: @pseudo_code

  @doc """
  Whether the development pseudo-localisation locale is enabled.

  Off everywhere except dev (see `config/dev.exs`); guarantees the pseudo locale
  can never render in production regardless of request input.
  """
  @spec pseudo_enabled?() :: boolean()
  def pseudo_enabled?, do: Application.get_env(:tymeslot, :pseudo_locale_enabled, false) == true

  @doc """
  Whether `code` may be applied as the request locale.

  A code is acceptable when it is a supported locale, or when it is the pseudo
  locale *and* pseudo-localisation is enabled. Use this at locale-resolution
  boundaries instead of a bare `code in supported_codes()` so the pseudo locale
  is honoured in dev without leaking into user-facing language pickers.
  """
  @spec acceptable?(term()) :: boolean()
  def acceptable?(code) when is_binary(code) do
    code in supported_codes() or (pseudo_enabled?() and code == @pseudo_code)
  end

  def acceptable?(_code), do: false

  @doc """
  Returns `code` unchanged when it is acceptable (see `acceptable?/1`), or
  `nil` otherwise.

  Designed for per-source locale-resolution `||` chains: an unacceptable
  candidate falls through to the next source instead of short-circuiting the
  chain and then being coerced to the default, which would silently discard a
  perfectly valid lower-priority source (e.g. a valid session locale behind a
  stale, unsupported user preference or an invalid `?locale=` param).
  """
  @spec acceptable(term()) :: String.t() | nil
  def acceptable(code) do
    if acceptable?(code), do: code
  end

  @doc """
  Returns the full list of supported locales from application configuration,
  each a `%{code:, name:, country_code:}` map. Returns an empty list if the
  configuration key is absent.
  """
  @spec supported() :: [%{code: String.t(), name: String.t(), country_code: atom()}]
  def supported do
    :tymeslot
    |> Application.get_env(:locales, [])
    |> Keyword.get(:supported, [])
  end

  @doc """
  Returns the list of supported locale codes from application configuration.
  Returns an empty list if the configuration key is absent.
  """
  @spec supported_codes() :: [String.t()]
  def supported_codes do
    Enum.map(supported(), & &1.code)
  end
end
