defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers do
  @moduledoc """
  Helper functions for the embed settings dashboard.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.HTML
  alias Tymeslot.Locales
  alias Tymeslot.Scheduling.ThemeFlow
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.Themes.Core.Context, as: ThemeContext

  # A slug segment of a snippet's address (`sanitize_username/1`).
  @slug_length [min_length: 1, max_length: 80]

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
  `:max_width`, `:username`, `:meeting_type`, `:base_url`, `:booking_url`
  and the link's `:prefill_name` and `:prefill_email` in one place so both
  the on-screen snippet renderer and the copy handler stay in sync.
  """
  @spec snippet_options(map()) :: map()
  def snippet_options(assigns) do
    %{
      username: assigns[:username],
      meeting_type: assigns[:meeting_type],
      base_url: assigns[:base_url],
      booking_url: assigns[:booking_url],
      layout: assigns[:embed_layout],
      locale: assigns[:embed_locale],
      initial_height: assigns[:initial_height],
      max_width: assigns[:max_width],
      prefill_name: assigns[:prefill_name],
      prefill_email: assigns[:prefill_email]
    }
  end

  @doc """
  The visitor details the link snippet carries, keyed `"name"` and `"email"`:
  only those the booking page will put in its form
  (`ThemeFlow.attendee_prefill/1`), so a value it would ignore is left out of
  the link rather than shipped in it.
  """
  @spec link_prefill(map()) :: %{optional(String.t()) => String.t()}
  def link_prefill(options),
    do:
      ThemeFlow.attendee_prefill(%{
        "name" => options[:prefill_name],
        "email" => options[:prefill_email]
      })

  @doc """
  The text a visitor sees on the popup button or the link snippet, in the
  embed's chosen language (see `localized_label/2`).

  Shared by `embed_code/2` and the live preview, so the preview shows the words
  the copied snippet will, in the same language.
  """
  @spec snippet_label(String.t(), map()) :: String.t()
  def snippet_label("popup", options),
    do: localized_label(options, fn -> dgettext("dashboard_embed", "Book a Meeting") end)

  def snippet_label("link", options),
    do: localized_label(options, fn -> dgettext("dashboard_embed", "Schedule a meeting") end)

  @doc """
  Generates the embed code snippet for a given type.
  """
  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("inline", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    type_attr = data_attr("meeting-type", sanitize_meeting_type(options[:meeting_type]))

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
    <div id="tymeslot-booking" data-username="#{username}"#{type_attr}#{attrs}></div>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("popup", %{username: username, base_url: base_url} = options) do
    username = sanitize_username(username)
    base_url = escape(base_url)
    js_options = build_js_options(options)

    label = escape(snippet_label("popup", options))
    href = popup_href(options)

    # A plain link to the booking page: a visitor whose embed.js never loaded
    # (blocked, slow, offline) still reaches the booking page in a new tab,
    # and never sees a native dialog. With the script present the click opens
    # the modal instead.
    String.trim("""
    <!-- Tymeslot Popup -->
    <a href="#{href}" target="_blank" rel="noopener" onclick="if(window.TymeslotBooking){event.preventDefault();TymeslotBooking.open('#{username}'#{js_options})}">#{label}</a>
    <script src="#{base_url}/embed.js" async></script>
    """)
  end

  @spec embed_code(String.t(), map()) :: String.t()
  def embed_code("link", %{booking_url: booking_url} = options) do
    booking_url = escape(booking_url)
    query = link_query(options)
    fragment = link_fragment(options)

    label = escape(snippet_label("link", options))

    String.trim("""
    <a href="#{booking_url}#{query}#{fragment}">#{label}</a>
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
  # TymeslotBooking.open / initFloating. Only includes sanitised values, the
  # meeting type first, as it says what the snippet opens.
  defp build_js_options(options) do
    js_list =
      [
        meetingType: sanitize_meeting_type(options[:meeting_type]),
        layout: layout_override_for_embed(options[:layout]),
        locale: sanitize_locale(options[:locale]),
        maxWidth: sanitize_int_in_range(options[:max_width], 200, 2000),
        primaryColor: sanitize_primary_color(options[:primary_color]),
        theme: sanitize_theme(options[:theme])
      ]
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

  # The visitor's name and email ride in the fragment, where the booking page
  # reads them (`ThemeUtils.assign_attendee_prefill/1`): a browser never sends
  # a fragment to a server, so they stay out of its access logs. Each value is
  # percent-encoded down to the unreserved characters, as the page decodes
  # them with `decodeURIComponent`, which also leaves nothing to escape in the
  # `href`.
  defp link_fragment(options) do
    prefill = link_prefill(options)

    pairs =
      for key <- ~w(name email),
          value = prefill[key],
          do: "#{key}=#{URI.encode(value, &URI.char_unreserved?/1)}"

    if pairs == [], do: "", else: "#" <> Enum.join(pairs, "&")
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
      "" -> Locales.booking_default_locale()
      locale -> locale
    end
  end

  # The popup snippet's fallback target: the public booking page, with the same
  # layout and language query as the link snippet. HTML-attribute-escaped (it
  # sits in an `href`, not in JS). Without a booking URL it is built from the
  # base URL and username, never left empty (an empty href reloads the host).
  defp popup_href(options) do
    base =
      case options[:booking_url] do
        url when is_binary(url) and url != "" -> url
        _none -> "#{options[:base_url]}/#{sanitize_username(options[:username])}"
      end

    escape(base <> link_query(options))
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

  # The address (a username, then optionally a booking page's slug, a meeting
  # type's, or both) is interpolated into HTML and JavaScript, so only one
  # whose every segment passes is emitted. The username takes the username
  # rules; a slug takes the same characters at a meeting type slug's length,
  # since those run from 1 to 80 characters where a username stops at 30. It
  # is never rewritten: a shortened address can be another organiser's page.
  defp sanitize_username(address) do
    [username | slugs] = String.split(address || "", "/")

    valid =
      length(slugs) <= 2 and valid_segment?(username, []) and
        Enum.all?(slugs, &valid_segment?(&1, @slug_length))

    if valid, do: address, else: "invalid-username"
  end

  # A meeting type's slug, emitted as an attribute and a JavaScript string:
  # one segment that passes as `sanitize_username/1`'s slugs do, else a
  # value that opens no page, never the overview the snippet was not for.
  defp sanitize_meeting_type(nil), do: nil

  defp sanitize_meeting_type(slug),
    do: if(valid_segment?(slug, @slug_length), do: slug, else: "invalid-meeting-type")

  defp valid_segment?(segment, opts),
    do: match?({:ok, ^segment}, InputProcessor.validate_field(segment, :username, opts))

  defp sanitize_theme(nil), do: nil

  defp sanitize_theme(theme) do
    theme = to_string(theme)
    if Regex.match?(~r/^\d+$/, theme), do: theme, else: nil
  end

  # The booking page reads the colour with `Colour.cast_hex/1`
  # (`ThemeContext.from_params/2`), so the snippet carries it in that form or
  # not at all.
  defp sanitize_primary_color(color) do
    case Colour.cast_hex(color) do
      {:ok, hex} -> hex
      :error -> nil
    end
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
