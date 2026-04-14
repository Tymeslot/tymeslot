defmodule Tymeslot.Emails.Templates.CalendarSyncError do
  @moduledoc """
  MJML template for calendar sync error notification sent to the calendar owner.
  """

  alias Tymeslot.Emails.Shared.{
    Callouts,
    MeetingComponents,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  alias Tymeslot.Profiles

  use Gettext, backend: TymeslotWeb.Gettext

  # A sync failure the user needs to act on.
  @intent :alert

  @type meeting_map :: %{
          required(:start_time) => DateTime.t(),
          required(:duration) => integer(),
          required(:location) => String.t() | nil,
          optional(:organizer_user_id) => term(),
          optional(atom()) => term()
        }

  @doc """
  Returns `{html_body, text_body}`, computing the owner's local start time only once.
  Prefer this over calling `render/2` and `render_text/2` separately when both bodies are needed.
  """
  @spec render_both(meeting_map(), any()) :: {String.t(), String.t()}
  def render_both(meeting, error_reason) do
    error_details = TemplateHelper.format_error_reason(error_reason)
    owner_start_time = owner_start_time(meeting)

    {do_render_html(error_details, owner_start_time, meeting),
     do_render_text(error_details, owner_start_time, meeting)}
  end

  @spec render(meeting_map(), any()) :: String.t()
  def render(meeting, error_reason) do
    error_details = TemplateHelper.format_error_reason(error_reason)
    do_render_html(error_details, owner_start_time(meeting), meeting)
  end

  @spec render_text(meeting_map(), any()) :: String.t()
  def render_text(meeting, error_reason) do
    error_details = TemplateHelper.format_error_reason(error_reason)
    do_render_text(error_details, owner_start_time(meeting), meeting)
  end

  defp do_render_html(error_details, owner_start_time, meeting) do
    mjml_content = """
    #{Callouts.alert_box(:cancelled,
    dgettext("emails",
    "I was unable to add this meeting to your calendar. The appointment has been successfully confirmed in Tymeslot and both you and the attendee have received confirmation emails. However, you'll need to manually add it to your calendar."),
    title: dgettext("emails", "Calendar Sync Error"))}

    #{Text.title_section(dgettext("emails", "Meeting Details"))}
    #{MeetingComponents.meeting_details_table(%{date: owner_start_time, start_time: owner_start_time, duration: meeting.duration, location: meeting.location})}

    #{Text.divider()}

    #{Text.title_section(dgettext("emails", "Error Details"))}

    #{Callouts.alert_box(:cancelled, error_details, title: dgettext("emails", "Error"))}

    #{Text.title_section(dgettext("emails", "Action Required"))}

    <mj-text color="#{Styles.ink_soft()}">
      #{dgettext("emails", "Please manually add this meeting to your calendar to ensure you don't miss it. Both you and the attendee have already received your confirmation emails — this is purely a technical calendar sync issue that doesn't affect the booking itself.")}
    </mj-text>

    #{Callouts.alert_box(:alert,
    dgettext("emails",
    "Common causes:<br/>• CalDAV server temporarily unavailable<br/>• Network connectivity issues<br/>• Calendar permissions or authentication problems<br/>• Maximum retries exceeded"))}

    #{Text.system_footer_note(dgettext("emails", "This is an automated system notification. Please check your calendar sync settings if this issue persists."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Calendar Sync Error"),
      dgettext("emails", "A meeting could not be added to your calendar."),
      intent: @intent,
      eyebrow: dgettext("emails", "Action required"),
      stage_title: dgettext("emails", "Calendar didn't sync"),
      stage_subtitle:
        dgettext("emails", "The booking is safe — but please add it to your calendar manually.")
    )
  end

  defp do_render_text(error_details, owner_start_time, meeting) do
    """
    #{dgettext("emails", "Calendar Sync Error — Manual Action Required")}

    #{dgettext("emails", "I was unable to add this meeting to your calendar. The appointment has been successfully confirmed in Tymeslot and both you and the attendee have received confirmation emails. However, you'll need to manually add it to your calendar.")}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{dgettext("emails", "Date:")} #{Calendar.strftime(owner_start_time, "%B %d, %Y")}
    #{dgettext("emails", "Time:")} #{Calendar.strftime(owner_start_time, "%I:%M %p")}
    #{dgettext("emails", "Duration:")} #{dgettext("emails", "%{count} minutes", count: meeting.duration)}
    #{dgettext("emails", "Location:")} #{meeting.location || dgettext("emails", "Not specified")}

    #{dgettext("emails", "ERROR DETAILS:")}
    #{error_details}

    #{dgettext("emails", "ACTION REQUIRED:")}
    #{dgettext("emails", "Please manually add this meeting to your calendar to ensure you don't miss it. Both you and the attendee have already received your confirmation emails — this is purely a technical calendar sync issue that doesn't affect the booking itself.")}

    #{dgettext("emails", "Common causes:")}
    - #{dgettext("emails", "CalDAV server temporarily unavailable")}
    - #{dgettext("emails", "Network connectivity issues")}
    - #{dgettext("emails", "Calendar permissions or authentication problems")}
    - #{dgettext("emails", "Maximum retries exceeded")}

    #{dgettext("emails", "This is an automated system notification. Please check your calendar sync settings if this issue persists.")}
    """
  end

  defp owner_start_time(meeting) do
    owner_timezone =
      case meeting.organizer_user_id do
        nil -> Profiles.get_default_timezone()
        user_id -> Profiles.get_user_timezone(user_id)
      end

    TimezoneHelper.convert_to_timezone(meeting.start_time, owner_timezone)
  end
end
