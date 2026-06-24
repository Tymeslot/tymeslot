defmodule TymeslotWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use TymeslotWeb, :controller` and
  `use TymeslotWeb, :live_view`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Endpoint

  embed_templates "layouts/*"

  @doc """
  Gets the canonical URL for use in canonical and meta tags.

  Always uses the configured endpoint base URL (consistent scheme and host) combined
  with the request path only — query parameters are intentionally excluded to avoid
  creating distinct canonical URLs for filtered/parameterised variants of the same page.
  Trailing slashes are normalised away (except for the root path) so that `/docs` and
  `/docs/` both produce the same canonical.
  """
  @spec current_url(map()) :: String.t()
  def current_url(assigns) do
    path =
      cond do
        assigns[:conn] -> assigns[:conn].request_path
        assigns[:uri] -> assigns[:uri].path
        true -> assigns[:request_path] || "/"
      end

    normalized_path =
      if path != "/" and String.ends_with?(path, "/"),
        do: String.trim_trailing(path, "/"),
        else: path

    Endpoint.url() <> normalized_path
  end

  @doc """
  Returns the absolute URL of the social-share (Open Graph) image for a
  scheduling page.

  Resolves in layers: the organiser's uploaded profile photo → a neutral
  default avatar → the Tymeslot brand card. The brand card is a defensive
  fallback used only when there is no organiser context (e.g. error pages).
  """
  @spec booking_og_image(map()) :: String.t()
  def booking_og_image(assigns) do
    Endpoint.url() <> booking_og_image_path(assigns[:organizer_profile])
  end

  defp booking_og_image_path(%ProfileSchema{} = profile) do
    Profiles.uploaded_avatar_path(profile) || ~p"/images/brand/default-avatar.png"
  end

  defp booking_og_image_path(_profile), do: ~p"/images/brand/og-image.png"

  @doc """
  Returns the Twitter card type for a scheduling page.

  A square avatar/photo pairs with the `summary` card; the wide brand fallback
  (no organiser context) pairs with `summary_large_image`.
  """
  @spec booking_twitter_card(map()) :: String.t()
  def booking_twitter_card(assigns) do
    if assigns[:organizer_profile], do: "summary", else: "summary_large_image"
  end

  @doc """
  Returns the social-share description for a scheduling page, personalised with
  the organiser's name when available.
  """
  @spec booking_og_description(map()) :: String.t()
  def booking_og_description(assigns) do
    case booking_organizer_name(assigns) do
      nil ->
        dgettext("booking", "Pick a time that works for you and book a meeting in seconds.")

      name ->
        dgettext("booking", "Book a meeting with %{name}. Pick a time that works for you.",
          name: name
        )
    end
  end

  defp booking_organizer_name(assigns) do
    case assigns[:organizer_profile] do
      %ProfileSchema{} = profile -> Profiles.display_name(profile) || assigns[:username_context]
      _no_organizer -> nil
    end
  end

  @doc """
  Renders the appropriate theme CSS link tag based on theme ID.
  """
  @spec render_theme_css(String.t()) :: Phoenix.LiveView.Rendered.t()
  def render_theme_css(theme_id) do
    theme_css_path =
      case theme_id do
        "1" -> ~p"/assets/scheduling-theme-quill.css"
        "2" -> ~p"/assets/scheduling-theme-rhythm.css"
        _other -> ~p"/assets/scheduling-theme-quill.css"
      end

    assigns = %{theme_css_path: theme_css_path}

    ~H"""
    <link phx-track-static rel="stylesheet" href={@theme_css_path} />
    """
  end

  @doc """
  Renders a full-screen noscript warning for browsers with JavaScript disabled.
  """
  attr :message, :string, required: true

  @spec noscript_warning(map()) :: Phoenix.LiveView.Rendered.t()
  def noscript_warning(assigns) do
    ~H"""
    <noscript>
      <div style="position: fixed; top: 0; left: 0; width: 100%; z-index: 999999; background: #be123c; color: white; padding: 12px 24px; text-align: center; font-family: system-ui, -apple-system, sans-serif; box-shadow: 0 4px 12px rgba(0,0,0,0.3); display: flex; align-items: center; justify-content: center; gap: 16px; border-bottom: 1px solid rgba(255,255,255,0.1);">
        <svg
          style="width: 20px; height: 20px; flex-shrink: 0; color: #fecdd3;"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
          />
        </svg>
        <span style="font-weight: 500; font-size: 14px; line-height: 1.4;">
          <strong style="text-transform: uppercase; font-size: 12px; letter-spacing: 0.05em; margin-right: 8px; color: #fecdd3;">
            JavaScript Disabled
          </strong>
          {@message}
        </span>
        <a
          href="."
          style="background: rgba(255,255,255,0.2); color: white; text-decoration: none; padding: 6px 14px; border-radius: 8px; font-size: 13px; font-weight: 700; white-space: nowrap; transition: background 0.2s;"
        >
          Refresh Page
        </a>
      </div>
    </noscript>
    """
  end

  @doc """
  Renders a fallback error message for browsers that don't support ES modules.
  This replaces the page content with a browser upgrade message.

  WARNING: The `context` attribute must only contain trusted, static strings.
  Never pass user-controlled input as it is embedded directly in JavaScript.
  """
  attr :context, :atom,
    default: :application,
    values: [:application, :scheduling_page],
    doc: "Static context identifier (atom) for the error message"

  attr :nonce, :string, default: nil, doc: "Per-request CSP nonce"

  @spec nomodule_fallback(map()) :: Phoenix.LiveView.Rendered.t()
  def nomodule_fallback(assigns) do
    # Convert atom to human-readable string safely
    assigns = assign(assigns, :context_str, context_to_string(assigns.context))

    ~H"""
    <script nomodule nonce={@nonce}>
      document.body.innerHTML = '<div style="padding: 2rem; text-align: center; font-family: system-ui, -apple-system, sans-serif; max-width: 600px; margin: 4rem auto;">' +
        '<svg style="width: 64px; height: 64px; margin: 0 auto 1.5rem; color: #dc2626;" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"></path></svg>' +
        '<h1 style="font-size: 1.5rem; font-weight: 700; color: #111827; margin-bottom: 0.75rem;">Browser Not Supported</h1>' +
        '<p style="color: #6b7280; line-height: 1.6; margin-bottom: 1.5rem;">This <%= @context_str %> requires a modern browser with ES module support. Please upgrade to the latest version of Chrome, Firefox, Safari, or Edge.</p>' +
        '<a href="https://browsehappy.com/" style="display: inline-block; padding: 0.75rem 1.5rem; background: #2563eb; color: white; text-decoration: none; border-radius: 0.5rem; font-weight: 500;">Learn About Modern Browsers</a>' +
        '</div>';
    </script>
    """
  end

  # Convert context atom to safe display string
  defp context_to_string(:application), do: "application"
  defp context_to_string(:scheduling_page), do: "scheduling page"

  @doc """
  Returns the theme-specific class name based on theme ID.
  Maps numeric IDs to semantic theme class names.
  """
  @spec theme_class(String.t()) :: String.t()
  def theme_class(theme_id) do
    case theme_id do
      "1" -> "quill-theme"
      "2" -> "rhythm-theme"
      _other -> "quill-theme"
    end
  end

  @doc """
  Renders generic theme extensions configured in the application environment.
  Allows external layers (like SaaS) to inject UI without Core awareness.
  """
  @spec render_theme_extensions(map()) :: Phoenix.LiveView.Rendered.t()
  def render_theme_extensions(assigns) do
    extensions = Application.get_env(:tymeslot, :theme_extensions, [])
    assigns = assign(assigns, :extensions, filter_valid_extensions(extensions))

    ~H"""
    <%= for {mod, func} <- @extensions do %>
      {apply(mod, func, [assigns])}
    <% end %>
    """
  end

  defp filter_valid_extensions(extensions) when is_list(extensions) do
    Enum.filter(extensions, fn
      {mod, func} when is_atom(mod) and is_atom(func) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, func, 1) do
          true
        else
          require Logger

          Logger.warning("Theme extension is configured but not available",
            module: inspect(mod),
            function: func
          )

          false
        end

      other ->
        require Logger
        Logger.error("Invalid theme extension configuration", value: inspect(other))
        false
    end)
  end

  defp filter_valid_extensions(_arg), do: []

  @doc """
  Renders analytics scripts based on application configuration.
  Currently supports Umami analytics.
  Returns empty content if no analytics providers are configured.
  """
  @spec analytics_scripts(map()) :: Phoenix.LiveView.Rendered.t()
  def analytics_scripts(assigns) do
    providers = Application.get_env(:tymeslot, :analytics_providers, nil)
    assigns = assign(assigns, :providers, filter_valid_providers(providers))

    ~H"""
    <%= for provider <- @providers do %>
      {render_provider_script(provider, assigns)}
    <% end %>
    """
  end

  @doc """
  Renders `preconnect` resource hints for the configured analytics origins so the
  DNS/TCP/TLS handshake to the tracker host overlaps with page render, rather than
  stalling the `defer`red analytics request. Renders nothing when analytics is
  unconfigured, and skips same-origin (relative) script URLs, which need no
  preconnect. Place it early in `<head>` for maximum overlap.
  """
  @spec analytics_preconnect(map()) :: Phoenix.LiveView.Rendered.t()
  def analytics_preconnect(assigns) do
    origins =
      :tymeslot
      |> Application.get_env(:analytics_providers, nil)
      |> filter_valid_providers()
      |> Enum.map(fn %{script_url: url} -> analytics_origin(url) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assigns = assign(assigns, :origins, origins)

    ~H"""
    <%= for origin <- @origins do %>
      <link rel="preconnect" href={origin} />
    <% end %>
    """
  end

  # Origin (scheme://host[:port]) of an analytics script URL, or nil for a
  # same-origin (relative) URL, which needs no preconnect.
  defp analytics_origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default_port = if scheme == "https", do: 443, else: 80

        if port && port != default_port do
          "#{scheme}://#{host}:#{port}"
        else
          "#{scheme}://#{host}"
        end

      _uri ->
        nil
    end
  end

  defp analytics_origin(_url), do: nil

  defp render_provider_script(%{provider: :umami, script_url: url, website_id: id}, assigns)
       when is_binary(url) and is_binary(id) do
    assigns =
      assigns
      |> assign(:url, url)
      |> assign(:id, id)

    ~H"""
    <script defer src={@url} data-website-id={@id}></script>
    """
  end

  defp render_provider_script(_other, assigns), do: ~H""

  defp filter_valid_providers(nil), do: []
  defp filter_valid_providers([]), do: []

  defp filter_valid_providers(providers) when is_list(providers) do
    Enum.filter(providers, fn provider ->
      case provider do
        %{provider: :umami, script_url: url, website_id: id}
        when is_binary(url) and is_binary(id) and url != "" and id != "" ->
          String.starts_with?(url, ["https://", "http://", "/"])

        _other ->
          false
      end
    end)
  end

  defp filter_valid_providers(_arg), do: []
end
