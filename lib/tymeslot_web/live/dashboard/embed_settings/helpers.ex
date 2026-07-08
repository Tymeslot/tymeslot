defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers do
  @moduledoc """
  Helper functions for the embed settings dashboard.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.HTML
  alias Tymeslot.Locales
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Themes.Core.Context, as: ThemeContext

  @doc "Returns the list of valid embed type strings."
  @spec valid_embed_types() :: [String.t()]
  def valid_embed_types, do: ~w(inline popup link floating)

  @doc "Returns the list of valid embed settings tab identifiers."
  @spec valid_tabs() :: [String.t()]
  def valid_tabs, do: ~w(options security preview)

  @doc "Returns the list of allowed layout values."
  @spec valid_layouts() :: [String.t()]
  def valid_layouts, do: ThemeContext.valid_layouts()

  @doc """
  Returns `{name, code}` tuples for the supported booking languages, for the
  embed language picker. The empty-value "Auto" option is added at the call
  site so its label can be translated.
  """
  @spec language_options() :: [{String.t(), String.t()}]
  def language_options do
    Enum.map(Locales.supported(), fn %{code: code, name: name} -> {name, code} end)
  end

  @doc """
  Builds the options map expected by `embed_code/2` from socket assigns.

  Remaps `:embed_layout` → `:layout` and collects `:initial_height`,
  `:max_width`, `:username`, `:base_url`, and `:booking_url` in one place
  so both the on-screen snippet renderer and the copy handler stay in sync.
  """
  @spec snippet_options(map()) :: map()
  def snippet_options(assigns) do
    %{
      username: assigns[:username],
      base_url: assigns[:base_url],
      booking_url: assigns[:booking_url],
      layout: assigns[:embed_layout],
      locale: assigns[:embed_locale],
      initial_height: assigns[:initial_height],
      max_width: assigns[:max_width]
    }
  end

  @doc """
  Generates the embed code snippet for a given type.
  """
  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("inline", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)

    attrs =
      Enum.join([
        data_attr("locale", sanitize_locale(options[:locale])),
        data_attr("theme", sanitize_theme(options[:theme])),
        data_attr("primary-color", sanitize_primary_color(options[:primary_color])),
        data_attr("layout", layout_override_for_embed(options[:layout])),
        data_attr("initial-height", sanitize_int_in_range(options[:initial_height], 200, 2000)),
        data_attr("max-width", sanitize_int_in_range(options[:max_width], 200, 2000))
      ])

    String.trim("""
    <!-- Tymeslot Inline -->
    <div id="tymeslot-booking" data-username="#{username}"#{attrs}></div>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("popup", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    js_options = build_js_options(options)

    label =
      escape(localized_label(options, fn -> dgettext("dashboard_embed", "Book a Meeting") end))

    unavailable =
      js_escape(
        localized_label(options, fn ->
          dgettext("dashboard_embed", "Booking system is currently unavailable.")
        end)
      )

    String.trim("""
    <!-- Tymeslot Popup -->
    <button onclick="if(window.TymeslotBooking){TymeslotBooking.open('#{username}'#{js_options})}else{alert('#{unavailable}')}">#{label}</button>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("link", %{booking_url: booking_url} = options) do
    booking_url = escape(booking_url)
    query = link_query(options)

    label =
      escape(
        localized_label(options, fn -> dgettext("dashboard_embed", "Schedule a meeting") end)
      )

    String.trim("""
    <a href="#{booking_url}#{query}">#{label}</a>
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

  # Builds the JS options string passed as the 2nd argument to
  # TymeslotBooking.open / initFloating. Only includes sanitised values.
  defp build_js_options(options) do
    js_list =
      %{
        locale: sanitize_locale(options[:locale]),
        theme: sanitize_theme(options[:theme]),
        primaryColor: sanitize_primary_color(options[:primary_color]),
        layout: layout_override_for_embed(options[:layout]),
        maxWidth: sanitize_int_in_range(options[:max_width], 200, 2000)
      }
      |> Enum.reject(fn {_k, v} -> v == nil || v == "" end)
      |> Enum.map(fn
        {k, v} when k == :maxWidth -> "#{k}: #{v}"
        {k, v} -> "#{k}: '#{v}'"
      end)

    case js_list do
      [] -> ""
      list -> ", {" <> Enum.join(list, ", ") <> "}"
    end
  end

  # Builds the query string for the standalone-link snippet from the layout
  # and locale knobs. Links open the booking page directly (no embed.js), so
  # both the wide-canvas override and the forced language must ride on the URL.
  # A user who picked "Column" wants the link to render wide (standalone
  # defaults to the centred :default); a chosen language forces that locale on
  # the booking page (otherwise it auto-detects from the visitor's browser).
  # "Default" layout matches the standalone default and is omitted.
  defp link_query(options) do
    params =
      Enum.reject(
        [{"layout", layout_query_value(options)}, {"locale", sanitize_locale(options[:locale])}],
        fn {_key, value} -> value in [nil, ""] end
      )

    case params do
      [] -> ""
      list -> "?" <> Enum.map_join(list, "&", fn {key, value} -> "#{key}=#{value}" end)
    end
  end

  defp layout_query_value(options) do
    case sanitize_layout(options[:layout]) do
      "column" -> "column"
      _other -> nil
    end
  end

  # Renders a snippet label in the embed's chosen language. When "Auto" is
  # selected (no forced locale) the label falls back to the configured default
  # locale — the booking page it links to will still auto-detect per visitor,
  # but the static button text has to commit to one language.
  defp localized_label(options, fun) do
    Gettext.with_locale(TymeslotWeb.Gettext, button_locale(options), fun)
  end

  defp button_locale(options) do
    case sanitize_locale(options[:locale]) do
      "" -> Locales.default_locale()
      locale -> locale
    end
  end

  # Escapes a translated string for safe interpolation inside a single-quoted
  # JS string literal (the popup snippet's alert fallback).
  defp js_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  # For embed snippets (inline + popup + floating), the server defaults every
  # embed to the centred `:default` layout (back-compat: snippets predating the
  # column layout carry no `data-layout`, and must keep the old centred default
  # on upgrade — see `Context.apply_layout/2`). So column is the value that
  # needs an explicit override: only a `data-layout="column"` snippet opts into
  # the wide canvas. "Default" matches the server default and produces a clean
  # snippet with no layout attribute.
  defp layout_override_for_embed(value) do
    case sanitize_layout(value) do
      "column" -> "column"
      _other -> nil
    end
  end

  defp data_attr(_name, nil), do: ""
  defp data_attr(_name, ""), do: ""
  defp data_attr(name, value), do: " data-#{name}=\"#{value}\""

  defp escape(nil), do: ""
  defp escape(val), do: val |> HTML.html_escape() |> HTML.safe_to_string()

  defp sanitize_username(username) do
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
    if Regex.match?(~r/^\d+$/, theme), do: theme, else: nil
  end

  defp sanitize_primary_color(nil), do: nil

  defp sanitize_primary_color(color) do
    color = to_string(color)

    if Regex.match?(~r/^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/, color),
      do: color,
      else: nil
  end

  defp sanitize_locale(nil), do: ""

  defp sanitize_locale(locale) do
    locale = to_string(locale)

    if Regex.match?(~r/^[a-z]{2}(-[a-zA-Z0-9]+)?$/, locale),
      do: locale,
      else: ""
  end

  # Layout is a strict allowlist matching the server-side context. Returns
  # the canonical string for any valid value (including "default"), or nil
  # for unknown values. The call site decides whether the result should
  # actually be emitted — see `layout_override_for_embed/1` and
  # `layout_query/1` for the context-specific emission rules.
  defp sanitize_layout(nil), do: nil

  defp sanitize_layout(value) do
    value = to_string(value)
    if value in valid_layouts(), do: value, else: nil
  end

  # Integer in inclusive range. Anything outside the range or non-numeric
  # returns nil so the data attribute is omitted entirely.
  defp sanitize_int_in_range(nil, _min, _max), do: nil
  defp sanitize_int_in_range("", _min, _max), do: nil

  defp sanitize_int_in_range(value, min, max) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= min and n <= max -> to_string(n)
      _invalid -> nil
    end
  end
end
