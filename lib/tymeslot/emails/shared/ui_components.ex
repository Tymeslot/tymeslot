defmodule Tymeslot.Emails.Shared.UiComponents do
  @moduledoc """
  General UI MJML components for email templates.
  Handles buttons, alerts, dividers, grids, and other basic UI elements.
  """

  alias Tymeslot.Emails.Shared.Styles

  @doc """
  Generates an action button.
  """
  @spec action_button(String.t(), String.t(), keyword()) :: String.t()
  def action_button(text, url, opts \\ []) do
    color = Keyword.get(opts, :color, "primary")
    width = Keyword.get(opts, :width, "200px")

    """
    <mj-button
      href="#{url}"
      background-color="#{Styles.button_color(color)}"
      color="#{Styles.button_text_color(color)}"
      border-radius="#{Styles.button_radius()}"
      font-size="15px"
      inner-padding="#{Styles.button_padding()}"
      width="#{width}"
      font-weight="600">
      #{text}
    </mj-button>
    """
  end

  @doc """
  Generates a group of action buttons.
  """
  @spec action_button_group(list(map())) :: String.t()
  def action_button_group(buttons) do
    button_html =
      Enum.map_join(buttons, "\n", fn button ->
        """
        <mj-column>
          #{action_button(button.text, button.url, button[:opts] || [])}
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
  Generates an alert/notification box.
  """
  @spec alert_box(String.t(), String.t(), keyword()) :: String.t()
  def alert_box(type, message, opts \\ []) do
    title = Keyword.get(opts, :title)

    """
    <mj-section padding="0">
      <mj-column>
        <mj-text 
          padding="12px 16px" 
          background-color="#{Styles.alert_background_color(type)}" 
          border-left="4px solid #{Styles.alert_border_color(type)}"
          font-size="14px"
          line-height="20px"
        >
          #{if title, do: "<strong>#{title}</strong><br/>", else: ""}
          #{message}
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
  Generates a title section with optional subtitle and icon.
  """
  @spec title_section(String.t(), keyword()) :: String.t()
  def title_section(title, opts \\ []) do
    subtitle = Keyword.get(opts, :subtitle)
    icon = Keyword.get(opts, :icon)
    align = Keyword.get(opts, :align, "left")

    """
    <mj-section padding="0 0 16px 0">
      <mj-column>
        #{if icon, do: ~s(<mj-image src="#{icon}" width="48px" padding-bottom="8px" align="#{align}" />), else: ""}
        <mj-text 
          font-size="22px" 
          font-weight="700" 
          color="#{Styles.text_color(:primary)}" 
          padding-bottom="#{if subtitle, do: "8px", else: "0"}" 
          align="#{align}"
          line-height="28px"
        >
          #{title}
        </mj-text>
        #{if subtitle, do: ~s(<mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" align="#{align}" line-height="22px">#{subtitle}</mj-text>), else: ""}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Generates a quick info grid showing key stats or information.
  Each item should have a :label and :value.
  """
  @spec quick_info_grid(list(map())) :: String.t()
  def quick_info_grid(items) when is_list(items) and length(items) > 0 do
    columns =
      Enum.map_join(items, "\n", fn item ->
        """
        <mj-column>
          <mj-text 
            align="center" 
            font-size="12px" 
            color="#{Styles.text_color(:secondary)}" 
            padding="0 0 2px 0"
          >
            #{item.label}
          </mj-text>
          <mj-text 
            align="center" 
            font-weight="600" 
            font-size="14px" 
            padding="0"
          >
            #{item.value}
          </mj-text>
        </mj-column>
        """
      end)

    """
    <mj-wrapper padding="8px 0">
      <mj-section background-color="#{Styles.meeting_color(:card_bg)}" border-radius="6px" padding="12px">
        <mj-group>
          #{columns}
        </mj-group>
      </mj-section>
    </mj-wrapper>
    """
  end

  def quick_info_grid(_), do: ""

  @doc """
  Generates a preparation checklist with items.
  """
  @spec preparation_checklist(list(String.t()), keyword()) :: String.t()
  def preparation_checklist(items, opts \\ [])

  def preparation_checklist(items, opts) when is_list(items) and length(items) > 0 do
    title = Keyword.get(opts, :title, "Checklist")
    type = Keyword.get(opts, :type, :default)

    {bg_color, text_color} =
      case type do
        :warning ->
          {Styles.background_color(:yellow_light), Styles.status_text_color(:warning_dark)}

        :info ->
          {Styles.component_color(:reminder_note), Styles.status_text_color(:info_dark)}

        _ ->
          {Styles.background_color(:green_light), Styles.status_text_color(:success_green)}
      end

    checklist_items = Enum.map_join(items, "<br/>", &"• #{&1}")

    """
    <mj-wrapper padding="8px 0">
      <mj-section background-color="#{bg_color}" border-radius="6px" padding="12px">
        <mj-column>
          <mj-text 
            font-size="13px" 
            font-weight="600" 
            color="#{text_color}" 
            padding="0 0 6px 0"
          >
            #{title}
          </mj-text>
          <mj-text 
            font-size="12px" 
            line-height="18px" 
            color="#{text_color}"
          >
            #{checklist_items}
          </mj-text>
        </mj-column>
      </mj-section>
    </mj-wrapper>
    """
  end

  def preparation_checklist(_, _), do: ""

  @doc """
  Generates footer actions section with action links.
  """
  @spec footer_actions(list(map())) :: String.t()
  def footer_actions(actions) when is_list(actions) and length(actions) > 0 do
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
    <mj-section padding="20px 0" background-color="#{Styles.background_color(:light)}">
      <mj-column>
        <mj-text align="center" font-size="14px" color="#{Styles.text_color(:secondary)}">
          #{action_links}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  def footer_actions(_), do: ""
end
