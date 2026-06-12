defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers do
  @moduledoc """
  Helper functions for the embed settings dashboard.
  """

  alias Phoenix.HTML
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

    String.trim("""
    <!-- Tymeslot Popup -->
    <button onclick="if(window.TymeslotBooking){TymeslotBooking.open('#{username}'#{js_options})}else{alert('Booking system is currently unavailable.')}">Book a Meeting</button>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("link", %{booking_url: booking_url} = options) do
    booking_url = escape(booking_url)
    query = layout_query(options)

    String.trim("""
    <a href="#{booking_url}#{query}">Schedule a meeting</a>
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

  # Appends ?layout=column to the standalone-link snippet. Links open the
  # booking page in a new tab/window where the standalone default is :default
  # (centred). A user who picked "Column" in the dashboard wants the link to
  # also render wide, so emit the override; "Default" matches the standalone
  # default and produces no query string.
  defp layout_query(options) do
    case sanitize_layout(options[:layout]) do
      "column" -> "?layout=column"
      _other -> ""
    end
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
