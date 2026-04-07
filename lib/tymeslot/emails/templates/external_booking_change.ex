defmodule Tymeslot.Emails.Templates.ExternalBookingChange do
  @moduledoc """
  Email template notifying an organizer that one of their Tymeslot meetings was
  either deleted or rescheduled directly in their external calendar.

  Sent by `Tymeslot.Emails.EmailService.send_external_booking_change/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TimezoneHelper
  }

  alias Tymeslot.Locales
  alias Tymeslot.Utils.UrlBuilder

  @type discrepancy :: :deleted | :modified

  @doc """
  Builds a Swoosh email notifying `organizer_email` that `meeting` was changed
  externally.  `discrepancy` is either `:deleted` or `:modified`.

  `owner_timezone` is the IANA timezone of the meeting organizer, used to
  convert the start time for display.
  """
  @spec build_email(Meeting.t(), String.t(), discrepancy(), String.t()) :: Swoosh.Email.t()
  def build_email(%Meeting{} = meeting, organizer_email, discrepancy, owner_timezone)
      when discrepancy in [:deleted, :modified] do
    locale = organizer_locale()
    owner_time = TimezoneHelper.convert_to_timezone(meeting.start_time, owner_timezone)
    date_short = SharedHelpers.format_date_short(owner_time, locale)

    html_body = render_html(meeting, owner_time, discrepancy, locale)
    text_body = render_text(meeting, owner_time, discrepancy, locale)

    MjmlEmail.base_email()
    |> to({meeting.organizer_name || organizer_email, organizer_email})
    |> subject(email_subject(discrepancy, meeting.title, date_short))
    |> html_body(html_body)
    |> text_body(text_body)
  end

  # ---------------------------------------------------------------------------
  # HTML rendering
  # ---------------------------------------------------------------------------

  defp render_html(meeting, owner_time, discrepancy, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = meeting.view_url || dashboard_url

    {alert_type, alert_message, alert_title} = alert_parts(discrepancy, meeting)
    safe_title = escape_html(meeting.title) || "Meeting"

    mjml_content = """
    #{Components.alert_box(alert_type, alert_message, title: alert_title)}

    #{Components.section_title(safe_title, padding: "24px 0 16px 0")}

    #{Components.meeting_details_table(%{date: owner_time, start_time: owner_time, duration: meeting.duration, location: meeting.location, location_type: if(meeting.meeting_url, do: :video, else: :custom), meeting_type: meeting.meeting_type},
    locale)}

    #{explanation_section(discrepancy)}

    #{Components.action_button("View Meeting Details", view_url, color: "primary", full_width: true)}

    #{Components.system_footer_note("This notification was triggered automatically when a change was detected in your external calendar.")}
    """

    organizer_details = %{
      name: meeting.organizer_name,
      email: meeting.organizer_email,
      title: meeting.organizer_title || "Tymeslot"
    }

    TemplateHelper.compile_template(mjml_content, organizer_details)
  end

  defp alert_parts(:deleted, meeting) do
    title = escape_html(meeting.title)

    {
      "error",
      "The meeting \"#{title}\" was deleted from your external calendar. Tymeslot still has this booking on record — please review and cancel it here if the meeting is no longer taking place.",
      "Meeting Deleted in External Calendar"
    }
  end

  defp alert_parts(:modified, meeting) do
    title = escape_html(meeting.title)

    {
      "warning",
      "The meeting \"#{title}\" was rescheduled in your external calendar. Tymeslot still holds the original booking — please review the details and update or cancel it accordingly.",
      "Meeting Rescheduled in External Calendar"
    }
  end

  defp explanation_section(:deleted) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#3f3f46" line-height="1.6">
          This meeting was <strong>removed from your external calendar</strong> but is still active in Tymeslot. If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp explanation_section(:modified) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#3f3f46" line-height="1.6">
          This meeting was <strong>rescheduled in your external calendar</strong>. Tymeslot still shows the original time above. If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details.
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  # ---------------------------------------------------------------------------
  # Plain-text rendering
  # ---------------------------------------------------------------------------

  defp render_text(meeting, owner_time, :deleted, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = meeting.view_url || dashboard_url

    """
    Meeting Deleted in External Calendar

    The meeting "#{meeting.title}" was deleted from your external calendar but is still active in Tymeslot.

    MEETING DETAILS:
    Date: #{SharedHelpers.format_date(owner_time, locale)}
    Time: #{SharedHelpers.format_time(owner_time, locale)}
    Duration: #{SharedHelpers.format_duration(meeting.duration, locale)}
    Location: #{meeting.location || "Not specified"}

    If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.

    View meeting:
    #{view_url}

    This notification was triggered automatically when a change was detected in your external calendar.
    """
  end

  defp render_text(meeting, owner_time, :modified, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = meeting.view_url || dashboard_url

    """
    Meeting Rescheduled in External Calendar

    The meeting "#{meeting.title}" was rescheduled in your external calendar. Tymeslot still holds the original booking shown below.

    ORIGINAL BOOKING DETAILS:
    Date: #{SharedHelpers.format_date(owner_time, locale)}
    Time: #{SharedHelpers.format_time(owner_time, locale)}
    Duration: #{SharedHelpers.format_duration(meeting.duration, locale)}
    Location: #{meeting.location || "Not specified"}

    If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details.

    View meeting:
    #{view_url}

    This notification was triggered automatically when a change was detected in your external calendar.
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Organizer locale — currently the system default. When per-user locale
  # preferences are added, resolve from the meeting's organizer_user_id.
  defp organizer_locale, do: Locales.default_locale()

  defp email_subject(:deleted, title, date_short),
    do: "Action required: \"#{title}\" was deleted from your external calendar (#{date_short})"

  defp email_subject(:modified, title, date_short),
    do: "Action required: \"#{title}\" was rescheduled in your external calendar (#{date_short})"

  defp escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp escape_html(nil), do: nil
end
