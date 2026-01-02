defmodule Tymeslot.Emails.Shared.CalendarComponents do
  @moduledoc """
  Calendar-related MJML components for email templates.
  Handles calendar links, attendee information, and scheduling-specific elements.
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}

  @doc """
  Generates calendar integration links section.
  """
  @spec calendar_links_section(map()) :: String.t()
  def calendar_links_section(meeting_details) do
    links = SharedHelpers.calendar_links(meeting_details)

    """
    <mj-section padding="16px 0" background-color="#{Styles.calendar_color(:bg_light)}">
      <mj-column>
        <mj-text 
          align="center" 
          font-size="14px" 
          color="#{Styles.calendar_color(:text_muted)}" 
          padding-bottom="12px"
        >
          Add to your calendar:
        </mj-text>
      </mj-column>
    </mj-section>
    <mj-section padding="0 0 16px 0" background-color="#{Styles.calendar_color(:bg_light)}">
      <mj-group>
        <mj-column>
          <mj-button 
            href="#{links.google}" 
            background-color="#{Styles.calendar_color(:button_white)}" 
            color="#{Styles.component_color(:link)}" 
            border="1px solid #{Styles.border_color(:light_gray)}" 
            border-radius="6px" 
            font-size="13px" 
            inner-padding="8px 16px"
            width="90px"
          >
            Google
          </mj-button>
        </mj-column>
        <mj-column>
          <mj-button 
            href="#{links.outlook}" 
            background-color="#{Styles.calendar_color(:button_white)}" 
            color="#{Styles.component_color(:link)}" 
            border="1px solid #{Styles.border_color(:light_gray)}" 
            border-radius="6px" 
            font-size="13px" 
            inner-padding="8px 16px"
            width="90px"
          >
            Outlook
          </mj-button>
        </mj-column>
        <mj-column>
          <mj-button 
            href="#{links.yahoo}" 
            background-color="#{Styles.calendar_color(:button_white)}" 
            color="#{Styles.component_color(:link)}" 
            border="1px solid #{Styles.border_color(:light_gray)}" 
            border-radius="6px" 
            font-size="13px" 
            inner-padding="8px 16px"
            width="90px"
          >
            Yahoo
          </mj-button>
        </mj-column>
      </mj-group>
    </mj-section>
    """
  end

  @doc """
  Generates attendee information section.
  """
  @spec attendee_info_section(map()) :: String.t()
  def attendee_info_section(attendee) do
    """
    <mj-section padding="0 0 20px 0">
      <mj-column>
        <mj-text 
          font-size="16px" 
          font-weight="600" 
          padding-bottom="12px"
        >
          Attendee Information
        </mj-text>
        <mj-table #{Styles.table_attributes()} css-class="responsive-table">
          <tr style="#{Styles.table_row_style()}">
            <td style="#{Styles.table_label_style()}">Name:</td>
            <td style="#{Styles.table_value_style()}">#{attendee.name}</td>
          </tr>
          <tr style="#{Styles.table_row_style()}">
            <td style="#{Styles.table_label_style()}">Email:</td>
            <td style="#{Styles.table_value_style()}">
              <a href="mailto:#{attendee.email}" style="color: #{Styles.component_color(:link)};">#{attendee.email}</a>
            </td>
          </tr>
          #{if attendee[:phone], do: phone_row(attendee.phone), else: ""}
          #{if attendee[:company], do: company_row(attendee.company), else: ""}
          #{if attendee[:timezone], do: timezone_row(attendee.timezone), else: ""}
        </mj-table>
      </mj-column>
    </mj-section>
    """
  end

  # Private helper functions

  defp phone_row(phone) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">Phone:</td>
      <td style="#{Styles.table_value_style()}">#{phone}</td>
    </tr>
    """
  end

  defp company_row(company) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">Company:</td>
      <td style="#{Styles.table_value_style()}">#{SharedHelpers.sanitize_for_email(company)}</td>
    </tr>
    """
  end

  defp timezone_row(timezone) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">Timezone:</td>
      <td style="#{Styles.table_value_style()}">#{timezone}</td>
    </tr>
    """
  end
end
