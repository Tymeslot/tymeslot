defmodule Tymeslot.Emails.Templates.ExternalBookingChange do
  @moduledoc """
  Email template notifying an organizer that one of their Tymeslot meetings was
  either deleted or rescheduled directly in their external calendar.

  Sent by `Tymeslot.Emails.EmailService.send_external_booking_change/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TextBodyHelper,
    TimezoneHelper
  }

  alias Tymeslot.Locales
  alias Tymeslot.Utils.UrlBuilder

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :alert

  @type discrepancy :: :deleted | :modified

  @doc """
  Builds a Swoosh email notifying `organizer_email` that `meeting` was changed
  externally.  `discrepancy` is either `:deleted` or `:modified`.

  `owner_timezone` is the IANA timezone of the meeting organizer, used to
  convert the start time for display.
  """
  @spec render(Meeting.t(), String.t(), discrepancy(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, organizer_email, discrepancy, owner_timezone)
      when discrepancy in [:deleted, :modified] do
    locale = organizer_locale()

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      owner_time = TimezoneHelper.convert_to_timezone(meeting.start_time, owner_timezone)
      date_short = Formatting.format_date_short(owner_time, locale)
      meeting = %{meeting | title: meeting.title || dgettext("emails", "Meeting")}

      html_body = render_html(meeting, owner_time, discrepancy, locale)
      text_body = render_text(meeting, owner_time, discrepancy, locale)

      MjmlEmail.base_email()
      |> to(recipient(meeting.organizer_name, organizer_email))
      |> subject(
        Sanitise.sanitize_for_header(email_subject(discrepancy, meeting.title, date_short))
      )
      |> html_body(html_body)
      |> text_body(text_body)
    end)
  end

  # Only attach a display name when the organiser actually has one — otherwise
  # a nil name would surface the bare email address as the recipient's name.
  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  # ---------------------------------------------------------------------------
  # HTML rendering
  # ---------------------------------------------------------------------------

  defp render_html(meeting, owner_time, discrepancy, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = meeting.view_url || dashboard_url

    {alert_intent, alert_message, alert_title} = alert_parts(discrepancy, meeting)
    safe_title = Sanitise.sanitize_for_email(meeting.title)

    mjml_content = """
    #{Callouts.alert_box(alert_intent, alert_message, title: alert_title)}

    #{Text.section_title(safe_title, padding: "24px 0 16px 0")}

    #{MeetingComponents.meeting_details_table(%{date: owner_time, start_time: owner_time, duration: meeting.duration, location: meeting.location, location_type: if(meeting.meeting_url, do: :video, else: :custom), meeting_type: meeting.meeting_type},
    locale)}

    #{MeetingComponents.custom_answers_section(meeting)}

    #{explanation_section(discrepancy)}

    #{Buttons.action_button(@intent, dgettext("emails", "View Meeting Details"), view_url, full_width: true)}

    #{Text.system_footer_note(dgettext("emails", "This notification was triggered automatically when a change was detected in your external calendar."))}
    """

    # This is an automated alert to the organiser about their own booking,
    # not a message from them — use the system layout so no organiser strip
    # frames it as "Message from <organiser>".
    TemplateHelper.compile_system_template(
      mjml_content,
      alert_title,
      dgettext("emails", "A meeting changed in your external calendar."),
      intent: @intent,
      eyebrow: dgettext("emails", "Action required"),
      stage_title: alert_title,
      stage_subtitle: dgettext("emails", "Please review and update the booking in Tymeslot.")
    )
  end

  defp alert_parts(:deleted, meeting) do
    title = Sanitise.sanitize_for_email(meeting.title)

    {
      :cancelled,
      dgettext(
        "emails",
        "The meeting \"%{title}\" was deleted from your external calendar. Tymeslot still has this booking on record — please review and cancel it here if the meeting is no longer taking place.",
        title: title
      ),
      dgettext("emails", "Meeting Deleted in External Calendar")
    }
  end

  defp alert_parts(:modified, meeting) do
    title = Sanitise.sanitize_for_email(meeting.title)

    {
      :alert,
      dgettext(
        "emails",
        "The meeting \"%{title}\" was rescheduled in your external calendar. Tymeslot still holds the original booking — please review the details and update or cancel it accordingly.",
        title: title
      ),
      dgettext("emails", "Meeting Rescheduled in External Calendar")
    }
  end

  defp explanation_section(:deleted) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="1.6">
          #{dgettext("emails", "This meeting was <strong>removed from your external calendar</strong> but is still active in Tymeslot. If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.")}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp explanation_section(:modified) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="1.6">
          #{dgettext("emails", "This meeting was <strong>rescheduled in your external calendar</strong>. Tymeslot still shows the original time above. If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details.")}
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
    custom_answers = TextBodyHelper.format_custom_answers(meeting, locale)

    """
    #{dgettext("emails", "Meeting Deleted in External Calendar")}

    #{dgettext("emails", "The meeting \"%{title}\" was deleted from your external calendar but is still active in Tymeslot.", title: meeting.title)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date(owner_time, locale)}
    #{dgettext("emails", "Time:")} #{Formatting.format_time(owner_time, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(meeting.duration, locale)}
    #{dgettext("emails", "Location:")} #{meeting.location || dgettext("emails", "Not specified")}
    #{custom_answers}
    #{dgettext("emails", "If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.")}

    #{dgettext("emails", "View meeting:")}
    #{view_url}

    #{dgettext("emails", "This notification was triggered automatically when a change was detected in your external calendar.")}
    """
  end

  defp render_text(meeting, owner_time, :modified, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = meeting.view_url || dashboard_url
    custom_answers = TextBodyHelper.format_custom_answers(meeting, locale)

    """
    #{dgettext("emails", "Meeting Rescheduled in External Calendar")}

    #{dgettext("emails", "The meeting \"%{title}\" was rescheduled in your external calendar. Tymeslot still holds the original booking shown below.", title: meeting.title)}

    #{dgettext("emails", "ORIGINAL BOOKING DETAILS:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date(owner_time, locale)}
    #{dgettext("emails", "Time:")} #{Formatting.format_time(owner_time, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(meeting.duration, locale)}
    #{dgettext("emails", "Location:")} #{meeting.location || dgettext("emails", "Not specified")}
    #{custom_answers}
    #{dgettext("emails", "If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details.")}

    #{dgettext("emails", "View meeting:")}
    #{view_url}

    #{dgettext("emails", "This notification was triggered automatically when a change was detected in your external calendar.")}
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Organizer locale — currently the system default. When per-user locale
  # preferences are added, resolve from the meeting's organizer_user_id.
  defp organizer_locale, do: Locales.default_locale()

  defp email_subject(:deleted, title, date_short),
    do:
      dgettext(
        "emails",
        "Action required: \"%{title}\" was deleted from your external calendar (%{date})",
        title: title,
        date: date_short
      )

  defp email_subject(:modified, title, date_short),
    do:
      dgettext(
        "emails",
        "Action required: \"%{title}\" was rescheduled in your external calendar (%{date})",
        title: title,
        date: date_short
      )
end
