defmodule TymeslotWeb.Components.Icons.IconComponents do
  @moduledoc """
  Shared icon components for consistent SVG icon rendering across the application.
  """

  use Phoenix.Component

  @doc """
  Returns the list of all supported icon names.
  Useful for validation and documentation.
  """
  @spec supported_icons() :: [atom()]
  def supported_icons do
    [
      :arrow_left,
      :arrow_right,
      :bell,
      :bolt,
      :calendar,
      :chat_bubble_left_right,
      :check,
      :clock,
      :cloudron,
      :code,
      :credit_card,
      :docker,
      :envelope,
      :grid,
      :home,
      :lock,
      :n8n,
      :paint_brush,
      :telegram,
      :pencil_square,
      :puzzle,
      :clipboard,
      :external_link,
      :swap,
      :user,
      :video,
      :webhook,
      :x_mark
    ]
  end

  @doc """
  Renders an SVG icon with consistent styling and attributes.

  ## Examples

      <.icon name="home" class="w-5 h-5" />
      <.icon name="user" class="w-6 h-6 text-blue-500" />

  """
  attr :name, :atom, required: true, doc: "The name of the icon to render"
  attr :class, :string, default: "w-5 h-5", doc: "CSS classes to apply to the SVG"
  attr :rest, :global, doc: "Additional HTML attributes"

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: :home} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"
      />
    </svg>
    """
  end

  def icon(%{name: :user} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
      />
    </svg>
    """
  end

  def icon(%{name: :grid} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"
      />
    </svg>
    """
  end

  def icon(%{name: :calendar} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
      />
    </svg>
    """
  end

  def icon(%{name: :video} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
      />
    </svg>
    """
  end

  def icon(%{name: :clock} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end

  def icon(%{name: :lock} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
      />
    </svg>
    """
  end

  def icon(%{name: :credit_card} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H5a3 3 0 00-3 3v8a3 3 0 003 3z"
      />
    </svg>
    """
  end

  def icon(%{name: :docker} = assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24" {@rest}>
      <path d="M13.983 11.078h2.119a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.119a.185.185 0 00-.185.185v1.888c0 .102.083.185.185.185m-2.954-5.43h2.118a.186.186 0 00.186-.186V3.574a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m0 2.716h2.118a.187.187 0 00.186-.186V6.29a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.887c0 .102.082.186.185.186m-2.93 0h2.12a.186.186 0 00.184-.186V6.29a.185.185 0 00-.185-.185H8.1a.185.185 0 00-.185.185v1.887c0 .102.083.186.185.186m-2.964 0h2.119a.186.186 0 00.185-.186V6.29a.185.185 0 00-.185-.185H5.136a.186.186 0 00-.186.185v1.887c0 .102.084.186.186.186m5.893 2.715h2.118a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m-2.93 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.083.185.185.185m-2.964 0h2.119a.185.185 0 00.185-.185V9.006a.185.185 0 00-.184-.186h-2.12a.186.186 0 00-.186.186v1.887c0 .102.084.185.186.185m-2.92 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.082.185.185.185M23.763 9.89c-.065-.051-.672-.51-1.954-.51-.338 0-.676.03-1.01.087-.248-1.7-1.653-2.53-1.716-2.566l-.344-.199-.226.327c-.284.438-.49.922-.612 1.43-.23.97-.09 1.882.403 2.661-.595.332-1.55.413-1.744.42H.751a.751.751 0 00-.75.748 11.376 11.376 0 00.692 4.062c.545 1.428 1.355 2.48 2.41 3.124 1.18.723 3.1 1.137 5.275 1.137.983.003 1.963-.086 2.93-.266a12.248 12.248 0 003.823-1.389c.98-.567 1.86-1.288 2.61-2.136 1.252-1.418 1.998-2.997 2.553-4.4h.221c1.372 0 2.215-.549 2.68-1.009.309-.293.55-.65.707-1.046l.098-.288z" />
    </svg>
    """
  end

  def icon(%{name: :cloudron} = assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24" {@rest}>
      <path d="M12 2L2 7v10c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V7l-10-5z" />
    </svg>
    """
  end

  def icon(%{name: :n8n} = assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24" {@rest}>
      <path d="M12 2c5.523 0 10 4.477 10 10s-4.477 10-10 10S2 17.523 2 12 6.477 2 12 2zm0 2a8 8 0 100 16 8 8 0 000-16zm1 8h3l-4 4-4-4h3V8h2v4z" />
    </svg>
    """
  end

  def icon(%{name: :telegram} = assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24" {@rest}>
      <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
    </svg>
    """
  end

  def icon(%{name: :code} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24" {@rest}>
      <path stroke-linecap="round" stroke-linejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5" />
    </svg>
    """
  end

  def icon(%{name: :arrow_left} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 19l-7-7m0 0l7-7m-7 7h18"
      />
    </svg>
    """
  end

  def icon(%{name: :arrow_right} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M14 5l7 7m0 0l-7 7m7-7H3"
      />
    </svg>
    """
  end

  def icon(%{name: :bell} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
      />
    </svg>
    """
  end

  def icon(%{name: :bolt} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13 10V3L4 14h7v7l9-11h-7z"
      />
    </svg>
    """
  end

  def icon(%{name: :webhook} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13 10V3L4 14h7v7l9-11h-7z"
      />
    </svg>
    """
  end

  def icon(%{name: :puzzle} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M11 4a2 2 0 114 0v1a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-1a2 2 0 100 4h1a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-1a2 2 0 10-4 0v1a1 1 0 01-1 1H7a1 1 0 01-1-1v-3a1 1 0 00-1-1H4a2 2 0 110-4h1a1 1 0 001-1V7a1 1 0 011-1h3a1 1 0 001-1V4z"
      />
    </svg>
    """
  end

  def icon(%{name: :paint_brush} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M7 21a4 4 0 01-4-4V5a2 2 0 012-2h4a2 2 0 012 2v12a4 4 0 01-4 4zm0 0h12a2 2 0 002-2v-4a6 6 0 00-3-5.197M11 3h8a2 2 0 012 2v4a6 6 0 01-3 5.197"
      />
    </svg>
    """
  end

  def icon(%{name: :chat_bubble_left_right} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"
      />
    </svg>
    """
  end

  def icon(%{name: :check} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end

  def icon(%{name: :envelope} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
      />
    </svg>
    """
  end

  def icon(%{name: :pencil_square} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
      />
    </svg>
    """
  end

  def icon(%{name: :swap} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
      />
    </svg>
    """
  end

  def icon(%{name: :x_mark} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M6 18L18 6M6 6l12 12"
      />
    </svg>
    """
  end

  def icon(%{name: :external_link} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
      />
    </svg>
    """
  end

  def icon(%{name: :clipboard} = assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
      />
    </svg>
    """
  end

  # Fallback for unknown icons
  def icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24" {@rest}>
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end
end
