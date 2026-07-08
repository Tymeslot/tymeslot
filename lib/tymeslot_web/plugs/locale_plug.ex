defmodule TymeslotWeb.Plugs.LocalePlug do
  @moduledoc """
  Detects and sets the user's preferred locale from various sources:
  1. Query parameter (?locale=de) - Highest priority, explicit user choice
  2. Session - User's previously selected locale
  3. Accept-Language header - Browser's preferred language
  4. Default fallback (en) - When no preference is detected

  The selected locale is stored in the session for persistence across requests
  and set in Gettext for translation rendering.

  Security: All locale inputs are sanitized and validated to prevent:
  - Path traversal attacks
  - Unicode bidirectional override attacks
  - Header injection attacks
  - DoS via extremely long inputs
  """
  alias TymeslotWeb.Themes.Shared.LocaleHandler
  import Plug.Conn
  require Logger

  @max_locale_length 10
  @max_header_length 1000
  @max_tags_count 20

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    user_locale =
      if Keyword.get(opts, :prefer_user_locale, false), do: get_locale_from_user(conn), else: nil

    locale =
      user_locale ||
        get_locale_from_params(conn) ||
        get_locale_from_session(conn) ||
        get_locale_from_header(conn) ||
        LocaleHandler.default_locale()

    # Validate locale is supported
    locale =
      if locale in LocaleHandler.supported_locales(),
        do: locale,
        else: LocaleHandler.default_locale()

    # Store in session for persistence
    conn = put_session(conn, :locale, locale)

    # Set for Gettext
    Gettext.put_locale(TymeslotWeb.Gettext, locale)

    # Store in assigns for LiveView access
    assign(conn, :locale, locale)
  end

  # The authenticated user's saved interface-language preference, when set.
  # Only consulted on pipelines that pass `prefer_user_locale: true` (the
  # authenticated app), never on public booking pages. Requires
  # `FetchCurrentUser` to have run earlier in the pipeline.
  defp get_locale_from_user(conn) do
    case conn.assigns[:current_user] do
      %{locale: locale} when is_binary(locale) -> sanitize_locale_input(locale)
      _other -> nil
    end
  end

  defp get_locale_from_params(conn) do
    case conn.params["locale"] do
      locale when is_binary(locale) -> sanitize_locale_input(locale)
      _other -> nil
    end
  end

  defp get_locale_from_session(conn) do
    case get_session(conn, :locale) do
      locale when is_binary(locale) -> sanitize_locale_input(locale)
      _other -> nil
    end
  end

  defp get_locale_from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
    |> find_best_match()
  end

  defp parse_accept_language(nil), do: []

  defp parse_accept_language(header) when is_binary(header) do
    # Validate UTF-8 and length before processing
    if String.valid?(header) and byte_size(header) <= @max_header_length do
      header
      |> String.split(",")
      |> Enum.take(@max_tags_count)
      |> Enum.map(&parse_language_tag/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_locale, quality} -> quality end, :desc)
    else
      Logger.warning("Invalid or oversized Accept-Language header",
        valid_utf8: String.valid?(header),
        size: byte_size(header)
      )

      []
    end
  end

  defp parse_accept_language(_arg), do: []

  defp parse_language_tag(tag) when is_binary(tag) do
    # Limit tag length to prevent DoS
    if byte_size(tag) > 100 do
      nil
    else
      case String.split(tag, ";q=") do
        [locale] ->
          case normalize_locale(locale) do
            normalized when is_binary(normalized) -> {normalized, 1.0}
            _other -> nil
          end

        [locale, quality] ->
          case Float.parse(quality) do
            # Validate quality score is within HTTP spec (0.0 to 1.0)
            {q, _value} when q >= 0.0 and q <= 1.0 ->
              case normalize_locale(locale) do
                normalized when is_binary(normalized) -> {normalized, q}
                _other -> nil
              end

            _other ->
              nil
          end

        _other ->
          nil
      end
    end
  end

  defp parse_language_tag(_arg), do: nil

  # Sanitizes locale input to prevent security issues.
  #
  # Protects against:
  # - Path traversal (../, ./, etc.)
  # - Unicode bidirectional override (U+202E, U+202D, etc.)
  # - Control characters
  # - Excessive length
  defp sanitize_locale_input(input) when is_binary(input) do
    # Check if input is valid UTF-8
    if String.valid?(input) do
      input
      |> String.trim()
      # Remove Unicode bidirectional override and control characters
      # Using String.to_charlist for proper Unicode handling
      |> then(fn str ->
        str
        |> String.to_charlist()
        |> Enum.reject(fn char ->
          # C0 and C1 control characters
          # Unicode bidirectional formatting characters
          (char >= 0x0000 and char <= 0x001F) or
            (char >= 0x007F and char <= 0x009F) or
            (char >= 0x200E and char <= 0x200F) or
            (char >= 0x202A and char <= 0x202E)
        end)
        |> List.to_string()
      end)
      # Remove any path traversal attempts
      |> String.replace(~r/\.\.|\.\/|\\\\/, "")
      |> normalize_locale()
    else
      Logger.warning("Invalid UTF-8 in locale input")
      nil
    end
  end

  defp normalize_locale(locale) when is_binary(locale) do
    normalized =
      locale
      |> String.trim()
      |> String.downcase()
      # Remove any non-alphanumeric characters except hyphen
      |> String.replace(~r/[^a-z0-9\-]/, "")
      |> String.split("-")
      |> List.first()
      # Truncate to maximum length
      |> then(fn
        nil -> nil
        str -> String.slice(str, 0, @max_locale_length)
      end)

    # Return nil if result is empty string
    case normalized do
      "" -> nil
      nil -> nil
      valid -> valid
    end
  end

  defp find_best_match([]), do: nil

  defp find_best_match(parsed_locales) do
    Enum.find_value(parsed_locales, fn {locale, _quality} ->
      if locale in LocaleHandler.supported_locales(), do: locale
    end)
  end
end
