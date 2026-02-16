defmodule Tymeslot.Emails.Shared.Styles do
  @moduledoc """
  Centralized styling configuration and design tokens for email templates.

  This module serves as the source of truth for the email design system, ensuring
  consistency with the Tymeslot web application (homepage and dashboard).

  ## Design Tokens

  ### Typography (Inter Font)
  - **Font Family**: Inter, system-ui, sans-serif
  - **Base Size**: 16px (for body text and buttons)
  - **Small Size**: 14px (for labels and secondary text)
  - **Weights**: 400 (Normal), 500 (Medium), 600 (Semibold), 700 (Bold), 800 (Extrabold)

  ### Color Palette (Turquoise Theme)
  - **Primary**: #14b8a6 (Turquoise-500)
  - **Primary Hover**: #0d9488 (Turquoise-600)
  - **Text Primary**: #18181b (Neutral-900)
  - **Text Secondary**: #52525b (Neutral-600)
  - **Background Light**: #fafafa (Neutral-50)
  - **Background Gray**: #f3f4f6 (Card background)

  ### Spacing & Borders
  - **Border Radius**: 12px for sections, 10px for buttons/cards, 8px for alerts
  - **Button Padding**: 16px 32px (Primary), 14px 28px (Secondary)
  - **Section Padding**: 24px - 28px for modern white-space

  ## Compatibility
  - Responsive design via MJML components and custom mobile overrides.
  - Dark mode support using `@media (prefers-color-scheme: dark)` and utility classes.
  """

  # ============================================================================
  # COLOR PALETTE - 2026 Glass Morphism Theme
  # ============================================================================

  # Primary Colors - Turquoise Gradient Theme
  # var(--color-primary-500)
  @primary_color "#14b8a6"
  # var(--color-primary-600)
  @primary_hover "#0d9488"
  @primary_dark "#0f766e"

  # Semantic Colors
  # var(--color-success)
  @success_color "#10b981"
  @success_hover "#059669"
  @success_light "#d1fae5"
  # var(--color-error)
  @danger_color "#ef4444"
  @danger_hover "#dc2626"
  @danger_light "#fee2e2"
  # var(--color-warning)
  @warning_color "#f59e0b"
  @warning_light "#fef3c7"
  # Using primary turquoise for info
  @info_color "#14b8a6"
  @info_light "#ccfbf1"

  # Text Colors - Enhanced hierarchy
  # var(--color-text-primary)
  @text_primary "#18181b"
  # var(--color-text-secondary)
  @text_secondary "#52525b"
  @text_muted "#71717a"
  @text_light "#a1a1aa"
  @text_dark "#3f3f46"
  @text_subtle "#9ca3af"

  # Background Colors - Layered depth system
  # var(--color-bg-secondary)
  @background_light "#fafafa"
  # var(--color-bg-primary)
  @background_white "#ffffff"
  @background_gray "#f3f4f6"
  @background_slate "#f8fafc"

  # Status backgrounds (lighter, more modern)
  @background_blue_light "#eff6ff"
  @background_red_light "#fef2f2"
  @background_yellow_light "#fffbeb"
  @background_green_light "#f0fdf4"
  @background_turquoise_subtle "#f0fdfa"

  # Border Colors - Softer, more refined
  # var(--color-border-light)
  @border_color "#e4e4e7"
  @border_gray "#e5e7eb"
  @border_subtle "#f0f0f1"
  @border_light_gray "#e4e4e7"

  # Accent borders
  @border_red "#fecaca"
  @border_yellow "#fde68a"

  # Calendar and component specific colors
  @calendar_bg_light "#f8f9fa"
  @calendar_button_white "#ffffff"
  @calendar_text_muted "#52525b"

  # Meeting component colors
  @meeting_card_bg "#f4f4f5"
  @notification_bg_blue "#f0f9ff"
  @notification_border_blue "#0284c7"
  @notification_text_blue "#0c4a6e"
  @notification_link_blue "#075985"

  # Status and state colors
  @status_badge_blue "#1e40af"
  @link_color "#14b8a6"
  @reminder_note_color "#e0e7ff"

  # Additional meeting colors
  @meeting_bg_teal_light "#f0fdfa"
  @meeting_text_teal "#0d9488"
  @success_text_dark "#065f46"
  @danger_text_dark "#991b1b"
  @warning_text_dark "#92400e"
  @info_text_dark "#3730a3"
  @success_text_green "#166534"

  # ============================================================================
  # TYPOGRAPHY - Inter Font System (2026)
  # ============================================================================

  @font_family "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

  # Font sizes - Refined scale
  @font_size_xs "12px"
  @font_size_sm "14px"
  @font_size_base "16px"
  @font_size_md "16px"
  @font_size_lg "18px"
  @font_size_xl "20px"
  @font_size_2xl "24px"
  @font_size_3xl "30px"

  # ============================================================================
  # SPACING - Harmonious scale
  # ============================================================================

  @spacing_0 "0"
  @spacing_xs "4px"
  @spacing_sm "8px"
  @spacing_md "12px"
  @spacing_lg "16px"
  @spacing_xl "24px"
  @spacing_2xl "32px"

  # Padding presets
  @padding_xs "4px"
  @padding_sm "6px"
  @padding_base "10px"
  @padding_md "14px"
  @padding_lg "16px"
  @padding_xl "20px"
  @padding_2xl "28px"

  # ============================================================================
  # COMPONENTS - Modern UI Elements
  # ============================================================================

  # Border radius - Softer, more rounded (2026 trend)
  @button_radius "12px"
  @card_radius "16px"
  @badge_radius "20px"

  @doc "Get button color based on type"
  @spec button_color(String.t()) :: String.t()
  def button_color("primary"), do: @primary_color
  def button_color("success"), do: @success_color
  def button_color("danger"), do: @danger_color
  def button_color("warning"), do: @warning_color
  def button_color(_type), do: @primary_color

  @doc "Get button hover color based on type"
  @spec button_hover_color(String.t()) :: String.t()
  def button_hover_color("primary"), do: @primary_hover
  def button_hover_color("success"), do: @success_hover
  def button_hover_color("danger"), do: @danger_hover
  def button_hover_color(_type), do: @primary_hover

  @doc "Get button text color based on type"
  @spec button_text_color(String.t()) :: String.t()
  def button_text_color(_type), do: @background_white

  @doc "Get alert background color based on type"
  @spec alert_background_color(String.t()) :: String.t()
  def alert_background_color("success"), do: "#f0fdf4"
  def alert_background_color("error"), do: "#fef2f2"
  def alert_background_color("warning"), do: "#fffbeb"
  def alert_background_color("info"), do: "#eff6ff"
  def alert_background_color(_type), do: @background_light

  @doc "Get alert border color based on type"
  @spec alert_border_color(String.t()) :: String.t()
  def alert_border_color("success"), do: @success_color
  def alert_border_color("error"), do: @danger_color
  def alert_border_color("warning"), do: @warning_color
  def alert_border_color("info"), do: @info_color
  def alert_border_color(_type), do: @border_color

  @doc "Button padding - More generous for modern feel"
  @spec button_padding(atom()) :: String.t()
  def button_padding(:large), do: "18px 36px"
  def button_padding(:medium), do: "14px 28px"
  def button_padding(:small), do: "10px 20px"
  def button_padding(_size), do: "16px 32px"

  @doc "Button font size"
  @spec button_font_size() :: String.t()
  def button_font_size, do: @font_size_md

  @doc "Button border radius"
  @spec button_radius() :: String.t()
  def button_radius, do: @button_radius

  @doc "Card border radius"
  @spec card_radius() :: String.t()
  def card_radius, do: @card_radius

  @doc "Badge border radius"
  @spec badge_radius() :: String.t()
  def badge_radius, do: @badge_radius

  @doc "Table attributes for MJML"
  @spec table_attributes() :: String.t()
  def table_attributes do
    ~s(width="100%" cellpadding="0" cellspacing="0" style="#{table_style()}")
  end

  @doc "Table style"
  @spec table_style() :: String.t()
  def table_style do
    "font-size: #{@font_size_md}; line-height: 1.6; color: #{@text_primary};"
  end

  @doc "Table row style"
  @spec table_row_style() :: String.t()
  def table_row_style do
    "border-bottom: 1px solid #{@border_color};"
  end

  @doc "Table label cell style"
  @spec table_label_style() :: String.t()
  def table_label_style do
    "padding: #{@spacing_md} #{@spacing_lg} #{@spacing_md} 0; font-weight: 700; color: #{@text_secondary}; width: 35%; min-width: 100px; font-size: 14px;"
  end

  @doc "Table value cell style"
  @spec table_value_style() :: String.t()
  def table_value_style do
    "padding: #{@spacing_md} 0; color: #{@text_primary}; word-break: break-word; font-size: 15px; font-weight: 500;"
  end

  @doc "Calendar link style"
  @spec calendar_link_style() :: String.t()
  def calendar_link_style do
    "color: #{@info_color}; text-decoration: none; font-weight: 600; padding: #{@spacing_sm} #{@spacing_md}; border: 1px solid #{@border_color}; border-radius: 10px; display: inline-block;"
  end

  @doc "Footer link style"
  @spec footer_link_style() :: String.t()
  def footer_link_style do
    "color: #{@text_secondary}; text-decoration: none;"
  end

  @doc "Get modern mobile styles with enhanced responsive behavior"
  @spec mobile_styles() :: String.t()
  def mobile_styles do
    """
    /* ====================================================================
       MOBILE RESPONSIVE STYLES (480px and below)
       ==================================================================== */
    @media only screen and (max-width: 480px) {
      .hide-mobile { display: none !important; }
      .show-mobile { display: block !important; }

      /* Typography adjustments */
      .mobile-heading {
        font-size: 24px !important;
        line-height: 1.3 !important;
      }
      .mobile-text {
        font-size: 15px !important;
        line-height: 1.5 !important;
      }

      /* Table adjustments for stacked layout */
      .responsive-table td {
        display: block !important;
        width: 100% !important;
        padding: 8px 0 !important;
        text-align: left !important;
      }
      .responsive-table td:first-child {
        font-weight: 700 !important;
        color: #52525b !important;
        padding-bottom: 4px !important;
        font-size: 14px !important;
      }
      .responsive-table tr {
        display: block !important;
        padding: 14px 0 !important;
        border-bottom: 1px solid #e4e4e7 !important;
      }

      /* Button adjustments */
      .mobile-button {
        width: 100% !important;
        padding: 16px 24px !important;
      }

      /* Card spacing */
      .mobile-card {
        margin: 12px 0 !important;
        padding: 16px !important;
      }
    }

    /* ====================================================================
       DARK MODE STYLES (Enhanced for 2026)
       ==================================================================== */
    @media (prefers-color-scheme: dark) {
      /* Core backgrounds */
      .dark-bg-primary {
        background-color: #09090b !important;
      }
      .dark-bg-secondary {
        background-color: #18181b !important;
      }
      .dark-bg-card {
        background-color: #27272a !important;
        border-color: #3f3f46 !important;
      }

      /* Text colors */
      .dark-text-primary {
        color: #fafafa !important;
      }
      .dark-text-secondary {
        color: #a1a1aa !important;
      }
      .dark-text-muted {
        color: #71717a !important;
      }

      /* Keep light theme for email body (better compatibility) */
      .force-light-bg {
        background-color: #ffffff !important;
      }
      .force-light-text {
        color: #18181b !important;
      }

      /* Dark mode accent adjustments */
      .dark-border {
        border-color: #3f3f46 !important;
      }

      /* Maintain button visibility in dark mode */
      .dark-button-primary {
        background-color: #14b8a6 !important;
        color: #ffffff !important;
      }
    }
    """
  end

  @doc "Get base MJML attributes for consistent styling"
  @spec mjml_base_attributes() :: String.t()
  def mjml_base_attributes do
    """
    <mj-attributes>
      <mj-all font-family="#{@font_family}" />
      <mj-text font-size="#{@font_size_md}" line-height="1.6" color="#{@text_primary}" padding="0" />
      <mj-section padding="0" />
      <mj-column padding="0" />
      <mj-button font-family="#{@font_family}" padding="0" />
      <mj-table font-family="#{@font_family}" />
    </mj-attributes>
    """
  end

  @doc "Get CSS styles for email head section - 2026 edition"
  @spec email_css_styles() :: String.t()
  def email_css_styles do
    """
    <mj-style>
      /* ================================================================
         MODERN DESIGN UTILITIES (2026)
         ================================================================ */

      /* Gradient backgrounds */
      .gradient-primary {
        background: linear-gradient(135deg, #{@primary_color} 0%, #{@primary_hover} 100%) !important;
      }

      .gradient-accent {
        background: linear-gradient(135deg, #06b6d4 0%, #0891b2 100%) !important;
      }

      .gradient-subtle {
        background: linear-gradient(180deg, #{@background_white} 0%, #{@background_light} 100%) !important;
      }

      /* Glass morphism hint (email-safe version) */
      .glass-card {
        background: #{@background_white};
        border: 1px solid #{@border_subtle};
        box-shadow: 0 4px 16px rgba(0, 0, 0, 0.04),
                    0 0 4px rgba(20, 184, 166, 0.03);
      }

      /* Modern shadows */
      .shadow-soft {
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.04);
      }

      .shadow-medium {
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
      }

      .shadow-strong {
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
      }

      .shadow-glow {
        box-shadow: 0 4px 16px rgba(20, 184, 166, 0.15);
      }

      /* Status badges */
      .badge {
        display: inline-block;
        padding: 6px 14px;
        border-radius: #{@badge_radius};
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.02em;
      }

      .badge-turquoise {
        background-color: #{@info_light};
        color: #{@primary_dark};
      }

      .badge-success {
        background-color: #{@success_light};
        color: #065f46;
      }

      .badge-warning {
        background-color: #{@warning_light};
        color: #92400e;
      }

      .badge-danger {
        background-color: #{@danger_light};
        color: #991b1b;
      }

      /* Link styles */
      a {
        color: #{@info_color};
        text-decoration: none;
        transition: color 0.2s ease;
      }

      a:hover {
        color: #{@primary_hover};
        text-decoration: none;
      }

      /* Card styles */
      .card {
        background: #{@background_white};
        border-radius: #{@card_radius};
        overflow: hidden;
      }

      .card-border {
        border: 1px solid #{@border_color};
      }

      /* Status indicators */
      .status-dot {
        display: inline-block;
        width: 8px;
        height: 8px;
        border-radius: 50%;
        margin-right: 6px;
      }

      .status-dot-success {
        background-color: #{@success_color};
      }

      .status-dot-warning {
        background-color: #{@warning_color};
      }

      #{mobile_styles()}
    </mj-style>
    """
  end

  @doc "Section padding presets"
  @spec section_padding(:small | :medium | :large | :xlarge) :: String.t()
  def section_padding(:small), do: "#{@spacing_xs} #{@spacing_lg}"
  def section_padding(:medium), do: "#{@spacing_sm} #{@spacing_lg}"
  def section_padding(:large), do: "#{@spacing_md} #{@spacing_lg}"
  def section_padding(:xlarge), do: "#{@spacing_lg} #{@spacing_lg}"

  # Font size getters
  @spec font_size(:xs | :sm | :base | :md | :lg | :xl | :"2xl" | :"3xl") :: String.t()
  def font_size(:xs), do: @font_size_xs
  def font_size(:sm), do: @font_size_sm
  def font_size(:base), do: @font_size_base
  def font_size(:md), do: @font_size_md
  def font_size(:lg), do: @font_size_lg
  def font_size(:xl), do: @font_size_xl
  def font_size(:"2xl"), do: @font_size_2xl
  def font_size(:"3xl"), do: @font_size_3xl

  # Text color getters
  @spec text_color(:primary | :secondary | :muted | :light | :dark | :subtle) :: String.t()
  def text_color(:primary), do: @text_primary
  def text_color(:secondary), do: @text_secondary
  def text_color(:muted), do: @text_muted
  def text_color(:light), do: @text_light
  def text_color(:dark), do: @text_dark
  def text_color(:subtle), do: @text_subtle

  # Background color getters
  @spec background_color(
          :white
          | :light
          | :gray
          | :slate
          | :blue_light
          | :red_light
          | :yellow_light
          | :green_light
          | :turquoise_subtle
        ) :: String.t()
  def background_color(:white), do: @background_white
  def background_color(:light), do: @background_light
  def background_color(:gray), do: @background_gray
  def background_color(:slate), do: @background_slate
  def background_color(:blue_light), do: @background_blue_light
  def background_color(:red_light), do: @background_red_light
  def background_color(:yellow_light), do: @background_yellow_light
  def background_color(:green_light), do: @background_green_light
  def background_color(:turquoise_subtle), do: @background_turquoise_subtle

  # Spacing getters
  @spec spacing(0 | :xs | :sm | :md | :lg | :xl | :"2xl") :: String.t()
  def spacing(0), do: @spacing_0
  def spacing(:xs), do: @spacing_xs
  def spacing(:sm), do: @spacing_sm
  def spacing(:md), do: @spacing_md
  def spacing(:lg), do: @spacing_lg
  def spacing(:xl), do: @spacing_xl
  def spacing(:"2xl"), do: @spacing_2xl

  # Padding getters
  @spec padding(:xs | :sm | :base | :md | :lg | :xl | :"2xl") :: String.t()
  def padding(:xs), do: @padding_xs
  def padding(:sm), do: @padding_sm
  def padding(:base), do: @padding_base
  def padding(:md), do: @padding_md
  def padding(:lg), do: @padding_lg
  def padding(:xl), do: @padding_xl
  def padding(:"2xl"), do: @padding_2xl

  # Border color getters
  @spec border_color(:default | :gray | :red | :yellow | :light_gray | :subtle) :: String.t()
  def border_color(:default), do: @border_color
  def border_color(:gray), do: @border_gray
  def border_color(:red), do: @border_red
  def border_color(:yellow), do: @border_yellow
  def border_color(:light_gray), do: @border_light_gray
  def border_color(:subtle), do: @border_subtle

  # Calendar component colors
  @spec calendar_color(:bg_light | :button_white | :text_muted) :: String.t()
  def calendar_color(:bg_light), do: @calendar_bg_light
  def calendar_color(:button_white), do: @calendar_button_white
  def calendar_color(:text_muted), do: @calendar_text_muted

  # Meeting component colors
  @spec meeting_color(:card_bg | :bg_teal_light | :text_teal) :: String.t()
  def meeting_color(:card_bg), do: @meeting_card_bg
  def meeting_color(:bg_teal_light), do: @meeting_bg_teal_light
  def meeting_color(:text_teal), do: @meeting_text_teal

  # Notification colors
  @spec notification_color(:bg_blue | :border_blue | :text_blue | :link_blue) :: String.t()
  def notification_color(:bg_blue), do: @notification_bg_blue
  def notification_color(:border_blue), do: @notification_border_blue
  def notification_color(:text_blue), do: @notification_text_blue
  def notification_color(:link_blue), do: @notification_link_blue

  # Other component colors
  @spec component_color(:status_badge_blue | :link | :reminder_note) :: String.t()
  def component_color(:status_badge_blue), do: @status_badge_blue
  def component_color(:link), do: @link_color
  def component_color(:reminder_note), do: @reminder_note_color

  # Status text colors
  @spec status_text_color(
          :success_dark
          | :danger_dark
          | :warning_dark
          | :info_dark
          | :success_green
        ) :: String.t()
  def status_text_color(:success_dark), do: @success_text_dark
  def status_text_color(:danger_dark), do: @danger_text_dark
  def status_text_color(:warning_dark), do: @warning_text_dark
  def status_text_color(:info_dark), do: @info_text_dark
  def status_text_color(:success_green), do: @success_text_green
end
