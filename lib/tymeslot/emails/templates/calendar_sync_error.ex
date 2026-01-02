defmodule Tymeslot.Emails.Templates.CalendarSyncError do
  @moduledoc """
  MJML template for calendar sync error notification sent to the calendar owner.
  """

  alias Tymeslot.Emails.Shared.{Components, TemplateHelper, TimezoneHelper}
  alias Tymeslot.Profiles

  @spec render(
          %{
            start_time: DateTime.t(),
            duration: integer(),
            location: String.t() | nil,
            organizer_user_id: any()
          },
          any()
        ) :: String.t()
  def render(meeting, error_reason) do
    error_details = TemplateHelper.format_error_reason(error_reason)

    # Get owner's timezone from meeting's organizer_user_id
    owner_timezone =
      case meeting.organizer_user_id do
        nil ->
          # Fallback to default timezone if organizer_user_id is missing
          "Europe/Kyiv"

        user_id ->
          Profiles.get_user_timezone(user_id)
      end

    # Convert meeting time to owner's timezone
    owner_start_time = TimezoneHelper.convert_to_timezone(meeting.start_time, owner_timezone)

    mjml_content = """
    #{Components.alert_box("error",
    "I was unable to add this meeting to your calendar. The appointment has been successfully confirmed in Tymeslot and both you and the attendee have received confirmation emails. However, you'll need to manually add it to your calendar.",
    title: "⚠️ Calendar Sync Error")}

    <!-- Main Content -->
    <mj-section background-color="#ffffff" border-radius="8px" padding="20px">
      <mj-column>
        #{Components.title_section("Meeting Details")}
        #{Components.meeting_details_table(%{date: owner_start_time, start_time: owner_start_time, duration: meeting.duration, location: meeting.location})}

        #{Components.divider()}

        #{Components.title_section("Error Details")}

        <mj-section background-color="#fef2f2" border="1px solid #fecaca" border-radius="6px" padding="12px">
          <mj-column>
            <mj-text color="#991b1b" font-size="13px" font-family="monospace">
              #{error_details}
            </mj-text>
          </mj-column>
        </mj-section>

        #{Components.title_section("Action Required")}

        <mj-text color="#3f3f46">
          Please manually add this meeting to your calendar to ensure you don't miss it. Both you and the attendee have already received your confirmation emails - this is purely a technical calendar sync issue that doesn't affect the booking itself.
        </mj-text>

        #{Components.alert_box("warning",
    "💡 Common causes:<br/>• CalDAV server temporarily unavailable<br/>• Network connectivity issues<br/>• Calendar permissions or authentication problems<br/>• Maximum retries exceeded")}
      </mj-column>
    </mj-section>

    <!-- Footer -->
    <mj-section padding="20px 0 0 0">
      <mj-column>
        <mj-text align="center" color="#52525b" font-size="12px">
          This is an automated system notification. Please check your calendar sync settings if this issue persists.
        </mj-text>
      </mj-column>
    </mj-section>
    """

    TemplateHelper.compile_system_template(mjml_content)
  end
end
