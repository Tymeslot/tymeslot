defmodule Tymeslot.Emails.Shared.CalendarComponents do
  @moduledoc """
  Calendar-related MJML components for email templates.

  Implements design tokens for integration links:
  - **Calendar Links**: 10px outer radius, 8px button radius, 14px text.
  - **Attendee Info**: 18px heading, 700 weight for labels, 500 weight for values.
  - **Tables**: Consistent 1px border (#e4e4e7), 16px row padding.
  """

  alias Tymeslot.Emails.Shared.{SharedHelpers, Styles}

  use Gettext, backend: TymeslotWeb.Gettext

  @type attendee_info :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(:phone) => String.t() | nil,
          optional(:company) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Generates calendar integration links section.
  """
  @spec calendar_links_section(%{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:description) => String.t(),
          required(:location) => String.t(),
          optional(atom()) => term()
        }) :: String.t()
  def calendar_links_section(meeting_details) do
    links = SharedHelpers.calendar_links(meeting_details)

    """
    <mj-section padding="20px 0 0 0" background-color="#{Styles.calendar_color(:bg_light)}" border-radius="10px">
      <mj-column>
        <mj-text
          align="center"
          font-size="15px"
          font-weight="600"
          color="#{Styles.calendar_color(:text_muted)}"
          padding-bottom="16px"
        >
          #{dgettext("emails", "Add to your calendar:")}
        </mj-text>
      </mj-column>
    </mj-section>
    <mj-section padding="0 0 20px 0" background-color="#{Styles.calendar_color(:bg_light)}" border-radius="0 0 10px 10px">
      <mj-group>
        <mj-column>
          <mj-button
            href="#{links.google}"
            background-color="#{Styles.calendar_color(:button_white)}"
            color="#{Styles.component_color(:link)}"
            border="1px solid #{Styles.border_color(:light_gray)}"
            border-radius="8px"
            font-size="14px"
            font-weight="600"
            inner-padding="10px 18px"
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
            border-radius="8px"
            font-size="14px"
            font-weight="600"
            inner-padding="10px 18px"
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
            border-radius="8px"
            font-size="14px"
            font-weight="600"
            inner-padding="10px 18px"
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
  @spec attendee_info_section(attendee_info()) :: String.t()
  def attendee_info_section(attendee) do
    safe_name = SharedHelpers.sanitize_for_email(attendee.name)
    safe_email = SharedHelpers.sanitize_for_email(attendee.email)

    """
    <mj-section padding="0 0 24px 0">
      <mj-column>
        <mj-text
          font-size="18px"
          font-weight="700"
          padding-bottom="16px"
        >
          Attendee Information
        </mj-text>
        <mj-table #{Styles.table_attributes()} css-class="responsive-table">
          <tr style="#{Styles.table_row_style()}">
            <td style="#{Styles.table_label_style()}">Name:</td>
            <td style="#{Styles.table_value_style()}">#{safe_name}</td>
          </tr>
          <tr style="#{Styles.table_row_style()}">
            <td style="#{Styles.table_label_style()}">Email:</td>
            <td style="#{Styles.table_value_style()}">
              <a href="mailto:#{safe_email}" style="color: #{Styles.component_color(:link)}; font-weight: 600; text-decoration: none;">#{safe_email}</a>
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
    safe_phone = SharedHelpers.sanitize_for_email(phone)

    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">Phone:</td>
      <td style="#{Styles.table_value_style()}">#{safe_phone}</td>
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
    safe_timezone = SharedHelpers.sanitize_for_email(timezone)

    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">Timezone:</td>
      <td style="#{Styles.table_value_style()}">#{safe_timezone}</td>
    </tr>
    """
  end
end
