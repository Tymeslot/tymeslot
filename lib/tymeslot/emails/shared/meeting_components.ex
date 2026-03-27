defmodule Tymeslot.Emails.Shared.MeetingComponents do
  @moduledoc """
  Modern meeting-specific MJML components for email templates (2026 Edition).

  Enhanced visual hierarchy and user experience:
  - **Details Card**: 16px radius, refined spacing, emoji icons, two-column grid layout
  - **Video Section**: Gradient backgrounds, prominent join button, context-aware styling
  - **Action Bars**: Responsive 1-3 button layouts, mobile-optimized spacing
  - **Time Badges**: Pill-shaped status indicators with semantic colors
  - **Meeting Type Tags**: Rounded badges with contextual coloring

  All components are:
  - Mobile-responsive with stacked layouts
  - Dark mode compatible
  - Cross-client tested (Gmail, Outlook, Apple Mail)
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}
  alias Tymeslot.Security.UrlValidation

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Generates a polished meeting details card with modern 2026 styling.
  Features refined typography, icon-label pairs, and responsive two-column grid.
  """
  @spec meeting_details_table(map()) :: String.t()
  def meeting_details_table(details), do: meeting_details_table(details, "en")

  @doc """
  Generates a locale-aware meeting details card.
  """
  @spec meeting_details_table(map(), String.t()) :: String.t()
  def meeting_details_table(details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      """
      <mj-section
        background-color="#{Styles.background_color(:gray)}"
        border-radius="#{Styles.card_radius()}"
        padding="16px 16px"
        css-class="mobile-card"
      >
        <mj-column>
          #{detail_row("📅", dgettext("emails", "Date"), SharedHelpers.format_date(details.date, locale), "🕐", dgettext("emails", "Time"), format_meeting_time(details, locale))}
          #{detail_row("⏱️", dgettext("emails", "Duration"), SharedHelpers.format_duration(details.duration, locale), location_icon(details[:location_type]), dgettext("emails", "Location"), SharedHelpers.format_location(details))}
          #{meeting_type_detail_section(details[:meeting_type])}
        </mj-column>
      </mj-section>
      """
    end)
  end

  @doc """
  Generates a prominent video meeting section with context-aware styling.

  Styles:
  - `:reminder` - Turquoise gradient, urgent feel for upcoming meetings
  - `:confirmation` - Success green, celebrating booking
  - `:subtle` - Minimal gray, for non-primary CTAs
  - `:default` - Standard turquoise theme

  Options:
  - `:title` - Section heading (default: "Join Video Meeting")
  - `:button_text` - CTA text (default: "Join Meeting")
  - `:show_time_note` - Boolean to show timing reminder
  """
  @spec video_meeting_section(String.t(), keyword()) :: String.t()
  def video_meeting_section(meeting_url, opts \\ []) do
    style = Keyword.get(opts, :style, :default)
    title = Keyword.get(opts, :title, dgettext("emails", "Join Video Meeting"))
    button_text_base = Keyword.get(opts, :button_text, dgettext("emails", "Join Meeting"))
    show_time_note = Keyword.get(opts, :show_time_note, false)

    # Sanitize user-provided text
    safe_title = SharedHelpers.sanitize_for_email(title)
    safe_button_text = SharedHelpers.sanitize_for_email(button_text_base)

    # Validate and sanitize URL
    safe_url =
      case UrlValidation.validate_http_url(meeting_url) do
        :ok ->
          SharedHelpers.sanitize_for_email(meeting_url)

        {:error, _reason} ->
          # If invalid, fallback to empty or '#'
          "#"
      end

    {bg_color, text_color, button_bg, button_text, css_class} =
      case style do
        :reminder ->
          {Styles.background_color(:turquoise_subtle), Styles.text_color(:dark),
           Styles.button_color("primary"), Styles.button_text_color("primary"), "gradient-subtle"}

        :confirmation ->
          {Styles.background_color(:green_light), Styles.status_text_color(:success_green),
           Styles.button_color("success"), Styles.button_text_color("success"), ""}

        :subtle ->
          {Styles.background_color(:light), Styles.text_color(:secondary),
           Styles.button_color("primary"), Styles.button_text_color("primary"), ""}

        _other ->
          {Styles.background_color(:turquoise_subtle), Styles.text_color(:dark),
           Styles.button_color("primary"), Styles.button_text_color("primary"), ""}
      end

    time_note = get_time_note_if_needed(show_time_note, style, text_color)

    """
    <mj-section
      padding="16px 16px 8px 16px"
      background-color="#{bg_color}"
      border-radius="#{Styles.card_radius()}"
      css-class="#{css_class} mobile-card"
    >
      <mj-column>
        <mj-text
          color="#{text_color}"
          font-size="18px"
          font-weight="700"
          align="center"
          padding="0 0 8px 0"
          line-height="1.2"
        >
          📹 #{safe_title}
        </mj-text>
        <mj-button
          href="#{safe_url}"
          background-color="#{button_bg}"
          color="#{button_text}"
          font-weight="700"
          align="center"
          width="auto"
          font-size="15px"
          inner-padding="14px 28px"
          border-radius="#{Styles.button_radius()}"
          css-class="mobile-button button-primary">
          #{safe_button_text}
        </mj-button>
        #{time_note}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a prominent time alert badge (e.g., "Starting in 1 hour").
  Perfect for reminder emails to create urgency and clarity.
  """
  @spec time_alert_badge(String.t(), keyword()) :: String.t()
  def time_alert_badge(time_text, opts \\ []) do
    icon = Keyword.get(opts, :icon, "⏰")
    color = Keyword.get(opts, :color, :blue)

    # Sanitize user-provided time text
    safe_time_text = SharedHelpers.sanitize_for_email(time_text)

    """
    <mj-section padding="0 0 8px 0">
      <mj-column>
        <mj-text align="center" padding="0">
          <span style="background-color: #{badge_background(color)}; color: #{badge_text_color(color)}; padding: 10px 20px; border-radius: #{Styles.badge_radius()}; font-size: 15px; font-weight: 700; display: inline-block; letter-spacing: 0.02em;">
            #{icon} #{safe_time_text}
          </span>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a properly aligned meeting actions bar using MJML best practices.
  Each action should have :text, :url, and optional :style (:primary, :secondary, :danger)
  """
  @spec meeting_actions_bar(list(map())) :: String.t()
  def meeting_actions_bar(actions) when is_list(actions) do
    case length(actions) do
      1 -> single_button_layout(actions)
      2 -> two_button_layout(actions)
      _other -> multi_button_layout(actions)
    end
  end

  @doc """
  Formats meeting time with timezone information.
  """
  @spec format_meeting_time(map()) :: String.t()
  def format_meeting_time(details), do: format_meeting_time(details, "en")

  @doc """
  Formats meeting time with timezone information, locale-aware.
  """
  @spec format_meeting_time(map(), String.t()) :: String.t()
  def format_meeting_time(details, locale) do
    case details do
      %{start_time: %DateTime{} = start_time, timezone: timezone} ->
        formatted_time = SharedHelpers.format_time(start_time, locale)

        if timezone && timezone != "UTC",
          do: "#{formatted_time} (#{timezone})",
          else: formatted_time

      %{start_time: %DateTime{} = start_time} ->
        SharedHelpers.format_time(start_time, locale)

      _other ->
        dgettext("emails", "TBD")
    end
  end

  # Private helper functions

  @spec single_button_layout(list(map())) :: String.t()
  defp single_button_layout([action]) do
    render_button(action,
      section_padding: "12px 0",
      font_size: "16px",
      inner_padding: Styles.button_padding(:large)
    )
  end

  @spec two_button_layout(list(map())) :: String.t()
  defp two_button_layout([primary_action, secondary_action]) do
    """
    <mj-section padding="12px 0">
      <mj-group>
        <mj-column>
          #{render_button(primary_action, wrap_in_section: false)}
        </mj-column>
        <mj-column>
          #{render_button(secondary_action, wrap_in_section: false)}
        </mj-column>
      </mj-group>
    </mj-section>
    """
  end

  @spec multi_button_layout(list(map())) :: String.t()
  defp multi_button_layout(actions) when length(actions) > 2 do
    Enum.map_join(actions, "\n", fn action ->
      render_button(action, section_padding: "8px 0")
    end)
  end

  @spec render_button(map(), keyword()) :: String.t()
  defp render_button(action, opts) do
    wrap_in_section = Keyword.get(opts, :wrap_in_section, true)
    section_padding = Keyword.get(opts, :section_padding, "0")
    font_size = Keyword.get(opts, :font_size, "15px")
    inner_padding = Keyword.get(opts, :inner_padding, Styles.button_padding(:medium))

    {bg_color, text_color, css_class} = get_action_button_colors(action)
    safe_text = SharedHelpers.sanitize_for_email(action.text)

    safe_url =
      case UrlValidation.validate_http_url(action.url) do
        :ok -> SharedHelpers.sanitize_for_email(action.url)
        _other -> "#"
      end

    button_mjml = """
    <mj-button
      href="#{safe_url}"
      background-color="#{bg_color}"
      color="#{text_color}"
      font-size="#{font_size}"
      font-weight="700"
      border-radius="#{Styles.button_radius()}"
      inner-padding="#{inner_padding}"
      width="auto"
      css-class="#{css_class} mobile-button">
      #{safe_text}
    </mj-button>
    """

    if wrap_in_section do
      """
      <mj-section padding="#{section_padding}">
        <mj-column>
          #{button_mjml}
        </mj-column>
      </mj-section>
      """
    else
      button_mjml
    end
  end

  @spec get_action_button_colors(map()) :: {String.t(), String.t(), String.t()}
  defp get_action_button_colors(action) do
    style = Map.get(action, :style, :primary)

    case style do
      :primary ->
        {Styles.button_color("primary"), Styles.button_text_color("primary"), "button-primary"}

      :secondary ->
        {Styles.background_color(:gray), Styles.text_color(:dark), ""}

      :danger ->
        {Styles.button_color("danger"), Styles.button_text_color("danger"), "button-danger"}

      _other ->
        {Styles.button_color("primary"), Styles.button_text_color("primary"), "button-primary"}
    end
  end

  defp get_time_note_if_needed(show_time_note, style, text_color) do
    if show_time_note do
      note_color =
        if style == :subtle, do: Styles.text_color(:secondary), else: darken_color(text_color)

      """
      <mj-text align="center" font-size="12px" color="#{note_color}" padding="8px 0 0 0">
        #{dgettext("emails", "Meeting will start at the scheduled time")}
      </mj-text>
      """
    else
      ""
    end
  end

  defp detail_row(icon1, label1, value1, icon2, label2, value2) do
    # Sanitize all user-provided labels and values
    safe_label1 = SharedHelpers.sanitize_for_email(label1)
    safe_value1 = SharedHelpers.sanitize_for_email(value1)
    safe_label2 = SharedHelpers.sanitize_for_email(label2)
    safe_value2 = SharedHelpers.sanitize_for_email(value2)

    """
    <mj-table width="100%" cellpadding="0" cellspacing="0">
      <tr>
        <td style="width: 50%; padding: 8px 12px 8px 0; vertical-align: top;">
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="width: 28px; vertical-align: top; padding-top: 2px;">
                <span style="font-size: 18px;">#{icon1}</span>
              </td>
              <td style="vertical-align: top;">
                <div style="font-size: #{Styles.font_size(:xs)}; color: #{Styles.text_color(:secondary)}; font-weight: 700; margin-bottom: 2px;">#{safe_label1}</div>
                <div style="font-size: #{Styles.font_size(:sm)}; color: #{Styles.text_color(:primary)}; font-weight: 500;">#{safe_value1}</div>
              </td>
            </tr>
          </table>
        </td>
        <td style="width: 50%; padding: 8px 0 8px 12px; vertical-align: top;">
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="width: 28px; vertical-align: top; padding-top: 2px;">
                <span style="font-size: 18px;">#{icon2}</span>
              </td>
              <td style="vertical-align: top;">
                <div style="font-size: #{Styles.font_size(:xs)}; color: #{Styles.text_color(:secondary)}; font-weight: 700; margin-bottom: 2px;">#{safe_label2}</div>
                <div style="font-size: #{Styles.font_size(:sm)}; color: #{Styles.text_color(:primary)}; font-weight: 500;">#{safe_value2}</div>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </mj-table>
    """
  end

  defp meeting_type_detail_section(nil), do: ""

  defp meeting_type_detail_section(meeting_type) do
    """
    <mj-divider border-color="#{Styles.border_color(:default)}" border-width="1px" padding="12px 0 8px 0" />
    <mj-text padding="0">
      <span style="background-color: #{Styles.background_color(:blue_light)}; color: #{Styles.component_color(:status_badge_blue)}; padding: 8px 16px; border-radius: 24px; font-size: #{Styles.font_size(:sm)}; font-weight: 700; display: inline-block;">
        #{SharedHelpers.sanitize_for_email(meeting_type)}
      </span>
    </mj-text>
    """
  end

  defp location_icon(:video), do: "📹"
  defp location_icon(:phone), do: "📞"
  defp location_icon(:in_person), do: "📍"
  defp location_icon(_location_type), do: "📍"

  defp badge_background(:blue), do: Styles.background_color(:blue_light)
  defp badge_background(:green), do: Styles.background_color(:green_light)
  defp badge_background(:red), do: Styles.background_color(:red_light)
  defp badge_background(_arg), do: Styles.background_color(:light)

  defp badge_text_color(:blue), do: Styles.component_color(:status_badge_blue)
  defp badge_text_color(:green), do: "#065f46"
  defp badge_text_color(:red), do: "#991b1b"
  defp badge_text_color(_arg), do: Styles.text_color(:secondary)

  defp darken_color("#ffffff"), do: Styles.component_color(:reminder_note)
  defp darken_color(color), do: color
end
