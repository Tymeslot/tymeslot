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
  """
  @spec default_locale() :: String.t()
  def default_locale do
    Application.get_env(:tymeslot, :locales, [])[:default] || "en"
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

  @doc """
  Resolves a raw `DEFAULT_LOCALE` environment value into a locale code.

  Returns `nil` when the value is absent or blank, so the caller leaves the
  configured default untouched. Raises `ArgumentError` for a code that is not
  supported: a deployment that asks for a language this build cannot render
  should stop at boot rather than quietly serve a different one.

  Called from `config/runtime.exs`; the pseudo locale is deliberately not
  accepted here, since it is a dev-only rendering aid rather than a language a
  deployment can choose to default to.
  """
  @spec default_from_env(term()) :: String.t() | nil
  def default_from_env(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      code ->
        codes = supported_codes()

        if code in codes do
          code
        else
          raise ArgumentError, """
          Invalid DEFAULT_LOCALE: #{inspect(code)}

          Supported locales: #{Enum.join(codes, ", ")}

          Leave DEFAULT_LOCALE unset to keep the built-in default.
          """
        end
    end
  end

  def default_from_env(_value), do: nil
end
