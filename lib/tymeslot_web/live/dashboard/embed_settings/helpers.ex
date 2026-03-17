defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers do
  @moduledoc """
  Helper functions for the embed settings dashboard.
  """

  alias Phoenix.HTML

  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.UniversalSanitizer

  @doc "Returns the list of valid embed type strings."
  @spec valid_embed_types() :: [String.t()]
  def valid_embed_types, do: ~w(inline popup link floating)

  @doc "Returns the list of valid embed settings tab identifiers."
  @spec valid_tabs() :: [String.t()]
  def valid_tabs, do: ~w(options security preview)

  @doc """
  Generates the embed code snippet for a given type.
  """
  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("inline", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    locale = sanitize_locale(options[:locale])
    data_locale = if locale != "", do: " data-locale=\"#{locale}\"", else: ""

    theme = sanitize_theme(options[:theme])
    data_theme = if theme, do: " data-theme=\"#{theme}\"", else: ""

    primary_color = sanitize_primary_color(options[:primary_color])

    data_primary_color =
      if primary_color, do: " data-primary-color=\"#{primary_color}\"", else: ""

    String.trim("""
    <!-- Tymeslot Inline -->
    <div id="tymeslot-booking" data-username="#{username}"#{data_locale}#{data_theme}#{data_primary_color}></div>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("popup", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    js_options = build_js_options(options)

    String.trim("""
    <!-- Tymeslot Popup -->
    <button onclick="if(window.TymeslotBooking){TymeslotBooking.open('#{username}'#{js_options})}else{alert('Booking system is currently unavailable.')}">Book a Meeting</button>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("link", %{booking_url: booking_url}) do
    booking_url = escape(booking_url)

    String.trim("""
    <a href="#{booking_url}">Schedule a meeting</a>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("floating", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    js_options = build_js_options(options)

    String.trim("""
    <!-- Tymeslot Floating Button -->
    <script src="#{base_url}/embed.js" async></script>
    <script>
      (function() {
        var init = function() {
          if (window.TymeslotBooking) {
            TymeslotBooking.initFloating('#{username}'#{js_options});
          } else {
            setTimeout(init, 100);
          }
        };
        init();
      })();
    </script>
    """)
  end

  @spec embed_code(any(), any()) :: String.t()
  def embed_code(_type, _assigns), do: ""

  defp build_js_options(options) do
    js_list =
      %{
        locale: sanitize_locale(options[:locale]),
        theme: sanitize_theme(options[:theme]),
        primaryColor: sanitize_primary_color(options[:primary_color])
      }
      |> Enum.reject(fn {_k, v} -> v == nil || v == "" end)
      |> Enum.map(fn {k, v} -> "#{k}: '#{v}'" end)

    case js_list do
      [] -> ""
      list -> ", {" <> Enum.join(list, ", ") <> "}"
    end
  end

  defp escape(nil), do: ""
  defp escape(val), do: val |> HTML.html_escape() |> HTML.safe_to_string()

  defp sanitize_username(username) do
    # 1. Apply universal sanitization (strips HTML, SQL patterns, dangerous protocols)
    # 2. Validate against username-specific rules (length, format, reserved words)
    # If invalid, we return an empty string to be safe, as the username is used in JS/HTML
    with {:ok, sanitized} <- UniversalSanitizer.sanitize_and_validate(username || ""),
         :ok <- UsernameValidator.validate(sanitized) do
      sanitized
    else
      {:error, _error} -> "invalid-username"
    end
  end

  defp sanitize_theme(nil), do: nil

  defp sanitize_theme(theme) do
    theme = to_string(theme)

    if Regex.match?(~r/^\d+$/, theme) do
      theme
    else
      nil
    end
  end

  defp sanitize_primary_color(nil), do: nil

  defp sanitize_primary_color(color) do
    color = to_string(color)

    if Regex.match?(~r/^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/, color) do
      color
    else
      nil
    end
  end

  defp sanitize_locale(nil), do: ""

  defp sanitize_locale(locale) do
    locale = to_string(locale)

    if Regex.match?(~r/^[a-z]{2}(-[a-zA-Z0-9]+)?$/, locale) do
      locale
    else
      ""
    end
  end
end
