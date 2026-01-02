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
  import TymeslotWeb.Components.CoreComponents

  embed_templates "layouts/*"

  @doc """
  Renders the appropriate theme CSS link tag based on theme ID.
  """
  @spec render_theme_css(String.t()) :: Phoenix.LiveView.Rendered.t()
  def render_theme_css(theme_id) do
    theme_css_path =
      case theme_id do
        "1" -> ~p"/assets/scheduling-theme-quill.css"
        "2" -> ~p"/assets/scheduling-theme-rhythm.css"
        _ -> ~p"/assets/scheduling-theme-quill.css"
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
  Returns the theme-specific class name based on theme ID.
  Maps numeric IDs to semantic theme class names.
  """
  @spec theme_class(String.t()) :: String.t()
  def theme_class(theme_id) do
    case theme_id do
      "1" -> "quill-theme"
      "2" -> "rhythm-theme"
      _ -> "quill-theme"
    end
  end
end
