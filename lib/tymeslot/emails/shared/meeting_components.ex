defmodule Tymeslot.Emails.Shared.MeetingComponents do
  @moduledoc """
  Meeting-specific MJML components for email templates.
  Handles meeting details, time formatting, video sections, and meeting actions.
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}

  @doc """
  Generates a modern meeting details card using pure MJML components with proper text spacing.
  """
  @spec meeting_details_table(map()) :: String.t()
  def meeting_details_table(details) do
    """
    <mj-section background-color="#{Styles.background_color(:gray)}" border-radius="12px" padding="24px">
      <mj-column>
        #{detail_row("📅", "Date", SharedHelpers.format_date(details.date), "🕐", "Time", format_meeting_time(details))}
        #{detail_row("⏱️", "Duration", SharedHelpers.format_duration(details.duration), location_icon(details[:location]), "Location", details[:location] || "TBD")}
        #{meeting_type_detail_section(details[:meeting_type])}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a video meeting section with different styles (reminder, confirmation, subtle).
  """
  @spec video_meeting_section(String.t(), keyword()) :: String.t()
  def video_meeting_section(meeting_url, opts \\ []) do
    style = Keyword.get(opts, :style, :default)
    title = Keyword.get(opts, :title, "Join Video Meeting")
    button_text_base = Keyword.get(opts, :button_text, "Join Meeting")
    show_time_note = Keyword.get(opts, :show_time_note, false)

    {bg_color, text_color, button_bg, button_text, border} =
      case style do
        :reminder ->
          {Styles.component_color(:link), Styles.background_color(:white),
           Styles.background_color(:white), Styles.component_color(:link), "none"}

        :confirmation ->
          {Styles.meeting_color(:bg_teal_light), Styles.meeting_color(:text_teal),
           Styles.component_color(:link), Styles.background_color(:white), "none"}

        :subtle ->
          {Styles.background_color(:light), Styles.text_color(:secondary),
           Styles.component_color(:link), Styles.background_color(:white),
           "1px solid #{Styles.border_color(:light_gray)}"}

        _ ->
          {Styles.component_color(:link), Styles.background_color(:white),
           Styles.background_color(:white), Styles.component_color(:link), "none"}
      end

    button_text_full =
      if style == :confirmation, do: "🎉 #{button_text_base}", else: button_text_base

    time_note = get_time_note_if_needed(show_time_note, style, text_color)

    """
    <mj-wrapper padding="12px 0">
      <mj-section 
        background-color="#{bg_color}" 
        border-radius="6px" 
        border="#{border}" 
        padding="16px"
      >
        <mj-column>
          <mj-text 
            color="#{text_color}" 
            font-size="16px" 
            font-weight="600" 
            align="center" 
            padding="0 0 12px 0"
          >
            📹 #{title}
          </mj-text>
          <mj-button
            href="#{meeting_url}"
            background-color="#{button_bg}"
            color="#{button_text}"
            font-weight="700"
            align="center"
            width="280px"
            font-size="15px"
            inner-padding="14px 24px"
            border-radius="6px">
            #{button_text_full}
          </mj-button>
          #{time_note}
        </mj-column>
      </mj-section>
    </mj-wrapper>
    """
  end

  @doc """
  Generates a time alert badge (e.g., "Starting in 1 hour").
  """
  @spec time_alert_badge(String.t(), keyword()) :: String.t()
  def time_alert_badge(time_text, opts \\ []) do
    icon = Keyword.get(opts, :icon, "⏰")
    color = Keyword.get(opts, :color, :blue)

    """
    <mj-section padding="8px 0">
      <mj-column>
        <mj-text align="center">
          <span style="background-color: #{badge_background(color)}; color: #{badge_text_color(color)}; padding: 6px 12px; border-radius: 16px; font-size: #{Styles.font_size(:sm)}; font-weight: 600; display: inline-block;">
            #{icon} #{time_text}
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
      _ -> multi_button_layout(actions)
    end
  end

  @doc """
  Formats meeting time with timezone information.
  """
  @spec format_meeting_time(map()) :: String.t()
  def format_meeting_time(details) do
    case details do
      %{start_time: start_time, timezone: timezone} when not is_nil(start_time) ->
        formatted_time = SharedHelpers.format_time(start_time)

        if timezone && timezone != "UTC",
          do: "#{formatted_time} (#{timezone})",
          else: formatted_time

      %{start_time: start_time} when not is_nil(start_time) ->
        SharedHelpers.format_time(start_time)

      _ ->
        "TBD"
    end
  end

  # Private helper functions

  @spec single_button_layout(list(map())) :: String.t()
  defp single_button_layout([action]) do
    {bg_color, text_color} = get_action_button_colors(action)

    """
    <mj-section padding="16px 0">
      <mj-column>
        <mj-button
          href="#{action.url}"
          background-color="#{bg_color}"
          color="#{text_color}"
          font-size="#{Styles.font_size(:base)}"
          font-weight="600"
          border-radius="#{Styles.button_radius()}"
          inner-padding="#{Styles.button_padding()}"
          width="300px">
          #{action.text}
        </mj-button>
      </mj-column>
    </mj-section>
    """
  end

  @spec two_button_layout(list(map())) :: String.t()
  defp two_button_layout([primary_action, secondary_action]) do
    {primary_bg, primary_text} = get_action_button_colors(primary_action)
    {secondary_bg, secondary_text} = get_action_button_colors(secondary_action)

    """
    <mj-section padding="16px 0">
      <mj-group>
        <mj-column>
          <mj-button
            href="#{primary_action.url}"
            background-color="#{primary_bg}"
            color="#{primary_text}"
            font-size="#{Styles.font_size(:base)}"
            font-weight="600"
            border-radius="#{Styles.button_radius()}"
            inner-padding="#{Styles.button_padding()}"
            width="180px">
            #{primary_action.text}
          </mj-button>
        </mj-column>
        <mj-column>
          <mj-button
            href="#{secondary_action.url}"
            background-color="#{secondary_bg}"
            color="#{secondary_text}"
            font-size="#{Styles.font_size(:base)}"
            font-weight="600"
            border-radius="#{Styles.button_radius()}"
            inner-padding="#{Styles.button_padding()}"
            width="180px">
            #{secondary_action.text}
          </mj-button>
        </mj-column>
      </mj-group>
    </mj-section>
    """
  end

  @spec multi_button_layout(list(map())) :: String.t()
  defp multi_button_layout(actions) when length(actions) > 2 do
    button_sections =
      Enum.map_join(actions, "\n", fn action ->
        {bg_color, text_color} = get_action_button_colors(action)

        """
        <mj-section padding="4px 0">
          <mj-column>
            <mj-button
              href="#{action.url}"
              background-color="#{bg_color}"
              color="#{text_color}"
              font-size="#{Styles.font_size(:base)}"
              font-weight="600"
              border-radius="#{Styles.button_radius()}"
              inner-padding="#{Styles.button_padding()}"
              width="260px">
              #{action.text}
            </mj-button>
          </mj-column>
        </mj-section>
        """
      end)

    """
    <mj-wrapper padding="16px 0">
      #{button_sections}
    </mj-wrapper>
    """
  end

  @spec get_action_button_colors(map()) :: {String.t(), String.t()}
  defp get_action_button_colors(action) do
    style = Map.get(action, :style, :primary)

    case style do
      :primary -> {Styles.button_color("primary"), Styles.button_text_color("primary")}
      :secondary -> {Styles.background_color(:light), Styles.text_color(:secondary)}
      :danger -> {Styles.button_color("danger"), Styles.button_text_color("danger")}
      _ -> {Styles.button_color("primary"), Styles.button_text_color("primary")}
    end
  end

  defp get_time_note_if_needed(show_time_note, style, text_color) do
    if show_time_note do
      note_color =
        if style == :subtle, do: Styles.text_color(:secondary), else: darken_color(text_color)

      """
      <mj-text align="center" font-size="12px" color="#{note_color}" padding="8px 0 0 0">
        Meeting will start at the scheduled time
      </mj-text>
      """
    else
      ""
    end
  end

  defp detail_row(icon1, label1, value1, icon2, label2, value2) do
    """
    <mj-table width="100%" cellpadding="0" cellspacing="0">
      <tr>
        <td style="width: 50%; padding: 8px 12px 8px 0; vertical-align: top;">
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="width: 28px; vertical-align: top; padding-top: 1px;">
                <span style="font-size: 16px;">#{icon1}</span>
              </td>
              <td style="vertical-align: top;">
                <div style="font-size: #{Styles.font_size(:sm)}; color: #{Styles.text_color(:secondary)}; font-weight: 600;">#{label1}</div>
                <div style="font-size: #{Styles.font_size(:base)}; color: #{Styles.text_color(:primary)}; margin-top: 2px;">#{value1}</div>
              </td>
            </tr>
          </table>
        </td>
        <td style="width: 50%; padding: 8px 0 8px 12px; vertical-align: top;">
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="width: 28px; vertical-align: top; padding-top: 1px;">
                <span style="font-size: 16px;">#{icon2}</span>
              </td>
              <td style="vertical-align: top;">
                <div style="font-size: #{Styles.font_size(:sm)}; color: #{Styles.text_color(:secondary)}; font-weight: 600;">#{label2}</div>
                <div style="font-size: #{Styles.font_size(:base)}; color: #{Styles.text_color(:primary)}; margin-top: 2px;">#{value2}</div>
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
    <div style="margin-top: 16px; padding-top: 12px; border-top: 1px solid #{Styles.border_color(:default)};">
      <span style="background-color: #{Styles.background_color(:blue_light)}; color: #{Styles.component_color(:status_badge_blue)}; padding: 8px 16px; border-radius: 20px; font-size: #{Styles.font_size(:sm)}; font-weight: 600; display: inline-block;">
        #{SharedHelpers.sanitize_for_email(meeting_type)}
      </span>
    </div>
    """
  end

  defp location_icon("Video Call"), do: "📹"
  defp location_icon("Phone Call"), do: "📞"
  defp location_icon("In Person"), do: "📍"
  defp location_icon(_), do: "📍"

  defp badge_background(:blue), do: Styles.background_color(:blue_light)
  defp badge_background(:green), do: Styles.background_color(:green_light)
  defp badge_background(:red), do: Styles.background_color(:red_light)
  defp badge_background(_), do: Styles.background_color(:light)

  defp badge_text_color(:blue), do: Styles.component_color(:status_badge_blue)
  defp badge_text_color(:green), do: "#065f46"
  defp badge_text_color(:red), do: "#991b1b"
  defp badge_text_color(_), do: Styles.text_color(:secondary)

  defp darken_color("#ffffff"), do: Styles.component_color(:reminder_note)
  defp darken_color(color), do: color
end
