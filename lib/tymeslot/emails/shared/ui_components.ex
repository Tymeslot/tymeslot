defmodule Tymeslot.Emails.Shared.UiComponents do
  @moduledoc """
  Modern UI MJML components for email templates (2026 Edition).

  Features enhanced design patterns:
  - **Buttons**: 12px radius (pill-shaped), bold text, shadow effects, gradient hover
  - **Alerts**: 12px radius, refined borders, status icons, improved backgrounds
  - **Titles**: Enhanced hierarchy, better spacing, optional gradient text
  - **Cards**: 16px radius, subtle shadows, glassmorphism hints
  - **Info Grids**: Card-based layout with refined typography
  - **Status Badges**: Rounded pills with semantic colors

  All components support:
  - Dark mode via CSS media queries
  - Mobile responsiveness
  - Accessibility standards
  - Cross-client compatibility
  """

  alias Tymeslot.Emails.Shared.SharedHelpers
  alias Tymeslot.Emails.Shared.Styles
  alias Tymeslot.Security.UrlValidation

  use Gettext, backend: TymeslotWeb.Gettext

  @type button_spec :: %{
          required(:text) => String.t(),
          required(:url) => String.t(),
          optional(:opts) => keyword(),
          optional(atom()) => term()
        }

  @type info_item :: %{required(:label) => String.t(), required(:value) => String.t()}

  @type action_item :: %{
          required(:text) => String.t(),
          required(:url) => String.t(),
          optional(:color) => atom()
        }

  @doc """
  Generates a centered logo header for system emails.
  """
  @spec logo_header() :: String.t()
  def logo_header do
    logo_data_uri = SharedHelpers.get_logo_data_uri()

    """
    <mj-section padding="24px 0 12px 0">
      <mj-column>
        <mj-image src="#{logo_data_uri}" width="200px" align="center" />
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a modern action button with enhanced styling.

  Options:
  - `:color` - "primary", "success", "danger", "warning" (default: "primary")
  - `:width` - Button width (default: "auto")
  - `:size` - :large, :medium, :small (default: :medium)
  - `:full_width` - Boolean for mobile responsiveness (default: false)
  """
  @spec action_button(String.t(), String.t(), keyword()) :: String.t()
  def action_button(text, url, opts \\ []) do
    color = Keyword.get(opts, :color, "primary")
    width = Keyword.get(opts, :width, "auto")
    size = Keyword.get(opts, :size, :medium)
    full_width = Keyword.get(opts, :full_width, false)

    """
    <mj-section padding="8px 0">
      <mj-column>
        #{button_markup(text, url, color, width, size, full_width)}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a group of action buttons.
  """
  @spec action_button_group(list(button_spec())) :: String.t()
  def action_button_group(buttons) do
    button_html =
      Enum.map_join(buttons, "\n", fn button ->
        opts = Map.get(button, :opts, [])
        color = Keyword.get(opts, :color, "primary")
        width = Keyword.get(opts, :width, "auto")
        size = Keyword.get(opts, :size, :medium)
        full_width = Keyword.get(opts, :full_width, false)

        """
        <mj-column>
          #{button_markup(button.text, button.url, color, width, size, full_width)}
        </mj-column>
        """
      end)

    """
    <mj-section padding="8px 0">
      <mj-group>
        #{button_html}
      </mj-group>
    </mj-section>
    """
  end

  @doc """
  Generates a modern alert/notification box with semantic styling.

  Options:
  - `:title` - Optional bold title for the alert
  - `:icon` - Optional emoji or icon prefix
  """
  @spec alert_box(String.t(), String.t(), keyword()) :: String.t()
  def alert_box(type, message, opts \\ []) do
    title = Keyword.get(opts, :title)
    icon = Keyword.get(opts, :icon)

    icon_prefix = if icon, do: "#{icon} ", else: ""
    safe_title = if title, do: SharedHelpers.sanitize_for_email(title)
    safe_message = SharedHelpers.sanitize_for_email(message)

    """
    <mj-section padding="0 0 4px 0">
      <mj-column>
        <mj-text
          padding="12px 16px"
          background-color="#{Styles.alert_background_color(type)}"
          border-left="4px solid #{Styles.alert_border_color(type)}"
          border-radius="#{Styles.card_radius()}"
          font-size="14px"
          line-height="1.4"
        >
          #{if title, do: "<strong style=\"font-weight: 700; font-size: 15px;\">#{icon_prefix}#{safe_title}</strong><br/>", else: ""}
          #{safe_message}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a small section title with centered alignment.
  """
  @spec section_title(String.t(), keyword()) :: String.t()
  def section_title(text, opts \\ []) do
    padding = Keyword.get(opts, :padding, "12px 0 8px 0")
    color = Keyword.get(opts, :color, Styles.text_color(:secondary))
    safe_text = SharedHelpers.sanitize_for_email(text)

    """
    <mj-section padding="#{padding}">
      <mj-column>
        <mj-text
          font-size="14px"
          font-weight="600"
          color="#{color}"
          align="center"
          css-class="mobile-text"
          text-transform="uppercase"
          letter-spacing="0.05em"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates centered text with standard styling.
  """
  @spec centered_text(String.t(), keyword()) :: String.t()
  def centered_text(text, opts \\ []) do
    font_size = Keyword.get(opts, :font_size, "16px")
    color = Keyword.get(opts, :color, Styles.text_color(:secondary))
    padding = Keyword.get(opts, :padding, "0 0 12px 0")
    safe_text = SharedHelpers.sanitize_for_email(text)

    """
    <mj-section padding="#{padding}">
      <mj-column>
        <mj-text
          font-size="#{font_size}"
          color="#{color}"
          line-height="1.5"
          align="center"
          css-class="mobile-text"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a system footer note (e.g., "If you didn't request this...")
  """
  @spec system_footer_note(String.t()) :: String.t()
  def system_footer_note(text) do
    safe_text = SharedHelpers.sanitize_for_email(text)

    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text
          font-size="14px"
          color="#{Styles.text_color(:muted)}"
          line-height="1.5"
          align="center"
          css-class="mobile-text"
        >
          #{safe_text}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a troubleshooting link section for buttons.
  URL is validated using Tymeslot.Security.UrlValidation.
  """
  @spec troubleshooting_link(String.t()) :: String.t()
  def troubleshooting_link(url) do
    # Validate and sanitize URL
    safe_url =
      case UrlValidation.validate_http_url(url) do
        :ok ->
          SharedHelpers.sanitize_for_email(url)

        {:error, _reason} ->
          # If invalid, we still sanitize for display but it won't be a working link
          # Or we could return empty string if we want to hide it
          SharedHelpers.sanitize_for_email(url)
      end

    """
    <mj-section padding="0">
      <mj-column>
        <mj-text
          font-size="13px"
          color="#{Styles.text_color(:muted)}"
          line-height="1.5"
          align="center"
        >
          #{dgettext("emails", "Having trouble with the button? Copy and paste this link into your browser:")}
        </mj-text>
        <mj-text
          font-size="12px"
          padding-top="12px"
          align="center"
        >
          <a href="#{safe_url}" style="color: #{Styles.component_color(:link)}; text-decoration: underline; word-break: break-all;">
            #{safe_url}
          </a>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a visual divider line.
  """
  @spec divider(keyword()) :: String.t()
  def divider(opts \\ []) do
    color = Keyword.get(opts, :color, Styles.border_color(:gray))
    margin = Keyword.get(opts, :margin, "20px 0")

    """
    <mj-section padding="#{margin}">
      <mj-column>
        <mj-divider border-color="#{color}" border-width="1px" />
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a modern title section with optional subtitle.

  Options:
  - `:subtitle` - Optional descriptive text below the title
  - `:icon` - Optional image URL for icon above title
  - `:align` - "left", "center", or "right" (default: "left")
  - `:emoji` - Optional emoji prefix for the title
  """
  @spec title_section(String.t(), keyword()) :: String.t()
  def title_section(title, opts \\ []) do
    subtitle = Keyword.get(opts, :subtitle)
    icon = Keyword.get(opts, :icon)
    emoji = Keyword.get(opts, :emoji)
    align = Keyword.get(opts, :align, "left")

    safe_title = SharedHelpers.sanitize_for_email(title)
    safe_subtitle = if subtitle, do: SharedHelpers.sanitize_for_email(subtitle)
    title_text = if emoji, do: "#{emoji} #{safe_title}", else: safe_title

    """
    <mj-section padding="0 0 #{if subtitle, do: "8", else: "4"}px 0">
      <mj-column>
        #{if icon, do: ~s(<mj-image src="#{icon}" width="48px" padding-bottom="8px" align="#{align}" />), else: ""}
        <mj-text
          font-size="24px"
          font-weight="800"
          color="#{Styles.text_color(:primary)}"
          padding-bottom="#{if subtitle, do: "4px", else: "0"}"
          align="#{align}"
          line-height="1.2"
          css-class="mobile-heading force-light-text"
        >
          #{title_text}
        </mj-text>
        #{if subtitle, do: ~s(<mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" align="#{align}" line-height="1.4" css-class="mobile-text">#{safe_subtitle}</mj-text>), else: ""}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a modern info grid with refined card styling.
  Each item should have :label and :value keys.
  Perfect for displaying key meeting details at a glance.

  Both label and value are sanitized for safe HTML output.
  """
  @spec quick_info_grid(list(info_item())) :: String.t()
  def quick_info_grid([_head | _tail] = items) do
    columns =
      Enum.map_join(items, "\n", fn item ->
        safe_label = SharedHelpers.sanitize_for_email(item.label)
        safe_value = SharedHelpers.sanitize_for_email(item.value)

        """
        <mj-column>
          <mj-text
            align="center"
            font-size="13px"
            color="#{Styles.text_color(:muted)}"
            padding="0 0 6px 0"
            font-weight="500"
            letter-spacing="0.02em"
          >
            #{safe_label}
          </mj-text>
          <mj-text
            align="center"
            font-weight="700"
            font-size="16px"
            padding="0"
            color="#{Styles.text_color(:primary)}"
          >
            #{safe_value}
          </mj-text>
        </mj-column>
        """
      end)

    """
    <mj-section
      padding="16px 12px 12px 12px"
      background-color="#{Styles.background_color(:gray)}"
      border-radius="#{Styles.card_radius()}"
      css-class="mobile-card"
    >
      <mj-group>
        #{columns}
      </mj-group>
    </mj-section>
    """
  end

  def quick_info_grid(_items), do: ""

  @doc """
  Generates a preparation checklist with items.
  """
  @spec preparation_checklist(list(String.t()), keyword()) :: String.t()
  def preparation_checklist(items, opts \\ [])

  def preparation_checklist([_head | _tail] = items, opts) do
    title = Keyword.get(opts, :title, "Checklist")
    type = Keyword.get(opts, :type, :default)

    {bg_color, text_color} =
      case type do
        :warning ->
          {Styles.background_color(:yellow_light), Styles.status_text_color(:warning_dark)}

        :info ->
          {Styles.component_color(:reminder_note), Styles.status_text_color(:info_dark)}

        _default ->
          {Styles.background_color(:green_light), Styles.status_text_color(:success_green)}
      end

    checklist_items =
      items
      |> Enum.map(&SharedHelpers.sanitize_for_email/1)
      |> Enum.map_join("<br/>", &"• #{&1}")

    """
    <mj-section padding="16px" background-color="#{bg_color}" border-radius="10px">
      <mj-column>
        <mj-text
          font-size="14px"
          font-weight="700"
          color="#{text_color}"
          padding="0 0 8px 0"
        >
          #{title}
        </mj-text>
        <mj-text
          font-size="14px"
          line-height="20px"
          color="#{text_color}"
        >
          #{checklist_items}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  def preparation_checklist(_items, _opts), do: ""

  @doc """
  Generates footer actions section with action links.
  """
  @spec footer_actions(list(action_item())) :: String.t()
  def footer_actions([_head | _tail] = actions) do
    action_links =
      Enum.map_join(actions, " | ", fn action ->
        color = Map.get(action, :color, :primary)

        link_color =
          if color == :danger,
            do: Styles.button_color("danger"),
            else: Styles.component_color(:link)

        "<a href=\"#{action.url}\" style=\"#{Styles.footer_link_style()}; color: #{link_color};\">#{action.text}</a>"
      end)

    """
    <mj-section padding="12px 0" background-color="#{Styles.background_color(:light)}">
      <mj-column>
        <mj-text align="center" font-size="14px" color="#{Styles.text_color(:secondary)}">
          #{action_links}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  def footer_actions(_actions), do: ""

  defp button_markup(text, url, color, width, size, full_width) do
    safe_text = SharedHelpers.sanitize_for_email(text)

    # Validate and sanitize URL (allowing mailto: for email buttons)
    safe_url =
      cond do
        String.starts_with?(url, "mailto:") ->
          SharedHelpers.sanitize_for_email(url)

        UrlValidation.validate_http_url(url) == :ok ->
          SharedHelpers.sanitize_for_email(url)

        true ->
          "#"
      end

    css_class = "button-#{color}#{if full_width, do: " mobile-button", else: ""}"

    """
    <mj-button
      href="#{safe_url}"
      background-color="#{Styles.button_color(color)}"
      color="#{Styles.button_text_color(color)}"
      border-radius="#{Styles.button_radius()}"
      font-size="#{Styles.font_size(:md)}"
      inner-padding="#{Styles.button_padding(size)}"
      width="#{width}"
      font-weight="700"
      css-class="#{css_class}">
      #{safe_text}
    </mj-button>
    """
  end
end
