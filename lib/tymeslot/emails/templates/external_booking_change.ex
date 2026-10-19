defmodule Tymeslot.Emails.Templates.ExternalBookingChange do
  @moduledoc """
  Email template notifying an organizer that one of their Tymeslot meetings was
  either deleted or rescheduled directly in their external calendar.

  Sent by `Tymeslot.Emails.EmailService.send_external_booking_change/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Bookings.MeetingLinks
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
    TextBodyHelper
  }

  alias Tymeslot.Utils.DateTimeUtils

  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Utils.UrlBuilder

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :alert

  @type discrepancy :: :deleted | :modified

  @typedoc "Who `render_end_followed/4` reports as told about a new end."
  @type end_notice :: %{
          previous_end_time: DateTime.t(),
          attendees: [String.t()],
          guests: non_neg_integer()
        }

  @doc """
  Builds a Swoosh email notifying `organizer_email` that `meeting` was changed
  externally.  `discrepancy` is either `:deleted` or `:modified`.

  `owner_timezone` is the IANA timezone of the meeting organizer, used to
  convert the start time for display.
  """
  @spec render(Meeting.t(), String.t(), discrepancy(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, organizer_email, discrepancy, owner_timezone)
      when discrepancy in [:deleted, :modified] do
    locale = RecipientLocale.locale_for_user_id(meeting.organizer_user_id)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      owner_time = DateTimeUtils.convert_to_timezone(meeting.start_time, owner_timezone)
      date_short = Formatting.format_date_short(owner_time, locale)

      meeting = %{
        MeetingLinks.with_current_links(meeting)
        | title: meeting.title || dgettext("emails_booking_changes", "Meeting")
      }

      # The host's own clock, as their other booking emails use.
      time_format = HostClock.time_format(meeting, locale)
      html_body = render_html(meeting, {owner_time, time_format}, discrepancy, locale)
      text_body = render_text(meeting, {owner_time, time_format}, discrepancy, locale)

      MjmlEmail.base_email()
      |> to(recipient(meeting.organizer_name, organizer_email))
      |> subject(email_subject(discrepancy, meeting.title, date_short))
      |> html_body(html_body)
      |> text_body(text_body)
    end)
  end

  @doc """
  Builds the email telling `organizer_email` that `meeting` now ends where they
  moved its end in their own calendar, and who was emailed the new end
  (`notice`). Nothing is asked of them: Tymeslot followed their calendar.
  """
  @spec render_end_followed(Meeting.t(), String.t(), end_notice(), String.t()) ::
          Swoosh.Email.t()
  def render_end_followed(%Meeting{} = meeting, organizer_email, notice, owner_timezone) do
    locale = RecipientLocale.locale_for_user_id(meeting.organizer_user_id)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      owner_time = DateTimeUtils.convert_to_timezone(meeting.start_time, owner_timezone)
      time_format = HostClock.time_format(meeting, locale)
      title = meeting.title || dgettext("emails_booking_changes", "Meeting")
      to = end_label(meeting.end_time, owner_time, locale, time_format)
      from = end_label(notice.previous_end_time, owner_time, locale, time_format)
      meeting = %{MeetingLinks.with_current_links(meeting) | title: title}

      summary =
        dgettext(
          "emails_booking_changes",
          "You changed when \"%{title}\" ends in your external calendar, so Tymeslot updated the booking: it now ends at %{to} instead of %{from}.",
          title: Sanitise.sanitize_for_email(title),
          to: to,
          from: from
        )

      told = told_line(meeting, notice)
      view_url = view_url(meeting, UrlBuilder.build_url("/dashboard/meetings"))

      mjml_content = """
      #{Callouts.alert_box(:confirmed, summary, title: dgettext("emails_booking_changes", "Meeting end updated from your calendar"))}

      #{Text.centered_text(Sanitise.sanitize_for_email(told), padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(%{date: owner_time, start_time: owner_time, duration: meeting.duration, location: meeting.location, location_type: if(meeting.meeting_url, do: :video, else: :custom), meeting_type: meeting.meeting_type, time_format: time_format}, locale)}

      #{Buttons.action_button(:confirmed, dgettext("emails_booking_changes", "View Meeting Details"), view_url, full_width: true)}

      #{Text.system_footer_note(dgettext("emails_booking_changes", "This notification was triggered automatically when a change was detected in your external calendar."))}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          dgettext("emails_booking_changes", "Meeting end updated from your calendar"),
          dgettext("emails_booking_changes", "A meeting changed in your external calendar."),
          intent: :confirmed,
          eyebrow: dgettext("emails_booking_changes", "Updated"),
          stage_title:
            dgettext("emails_booking_changes", "Meeting end updated from your calendar"),
          stage_subtitle: told
        )

      text_body = """
      #{dgettext("emails_booking_changes", "Meeting end updated from your calendar")}

      #{summary}

      #{told}

      #{dgettext("emails_booking_changes", "View meeting:")}
      #{view_url}

      #{dgettext("emails_booking_changes", "This notification was triggered automatically when a change was detected in your external calendar.")}
      """

      MjmlEmail.base_email()
      |> to(recipient(meeting.organizer_name, organizer_email))
      |> subject(
        dgettext("emails_booking_changes", "\"%{title}\" now ends at %{time} (%{date})",
          title: title,
          time: to,
          date: Formatting.format_date_short(owner_time, locale)
        )
      )
      |> html_body(html_body)
      |> text_body(text_body)
    end)
  end

  # The end in the host's zone and clock; on a later day than the start, with
  # its day.
  defp end_label(end_time, owner_start, locale, time_format) do
    finish = DateTimeUtils.convert_to_timezone(end_time, owner_start.time_zone)

    if Date.compare(DateTime.to_date(finish), DateTime.to_date(owner_start)) == :eq,
      do: Formatting.format_time(finish, locale, time_format),
      else: Formatting.format_datetime(finish, locale, time_format)
  end

  defp told_line(meeting, %{attendees: attendees, guests: guests}) do
    [attendees_line(meeting, attendees), guests_line(guests, attendees != [])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp attendees_line(_meeting, []), do: nil

  # Counts the participants reached, which on a retry or a rejected address
  # need not be all of them.
  defp attendees_line(meeting, attendees) do
    if Meeting.group?(meeting) do
      dngettext(
        "emails_booking_changes",
        "We emailed %{count} participant the new end time, with an updated calendar entry.",
        "We emailed %{count} participants the new end time, with an updated calendar entry.",
        length(attendees)
      )
    else
      dgettext(
        "emails_booking_changes",
        "We emailed %{name} the new end time, with an updated calendar entry.",
        name: Enum.join(attendees, ", ")
      )
    end
  end

  defp guests_line(0, _after_attendees?), do: nil

  defp guests_line(guests, true) do
    dngettext(
      "emails_booking_changes",
      "Their guest was emailed too.",
      "Their %{count} guests were emailed too.",
      guests
    )
  end

  # No attendee was reached, so "their" would have nobody to refer to.
  defp guests_line(guests, false) do
    dngettext(
      "emails_booking_changes",
      "We emailed the guest the new end time, with an updated calendar entry.",
      "We emailed %{count} guests the new end time, with an updated calendar entry.",
      guests
    )
  end

  # Only attach a display name when the organiser actually has one — otherwise
  # a nil name would surface the bare email address as the recipient's name.
  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  # ---------------------------------------------------------------------------
  # HTML rendering
  # ---------------------------------------------------------------------------

  defp render_html(meeting, {owner_time, time_format}, discrepancy, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = view_url(meeting, dashboard_url)

    {alert_intent, alert_message, alert_title} = alert_parts(discrepancy, meeting)
    safe_title = Sanitise.sanitize_for_email(meeting.title)

    mjml_content = """
    #{Callouts.alert_box(alert_intent, alert_message, title: alert_title)}

    #{Text.section_title(safe_title, padding: "24px 0 16px 0")}

    #{MeetingComponents.meeting_details_table(%{date: owner_time, start_time: owner_time, duration: meeting.duration, location: meeting.location, location_type: if(meeting.meeting_url, do: :video, else: :custom), meeting_type: meeting.meeting_type, time_format: time_format},
    locale)}

    #{MeetingComponents.custom_answers_section(meeting)}

    #{explanation_section(discrepancy, meeting)}

    #{Buttons.action_button(@intent, dgettext("emails_booking_changes", "View Meeting Details"), view_url, full_width: true)}

    #{Text.system_footer_note(dgettext("emails_booking_changes", "This notification was triggered automatically when a change was detected in your external calendar."))}
    """

    # This is an automated alert to the organiser about their own booking,
    # not a message from them — use the system layout so no organiser strip
    # frames it as "Message from <organiser>".
    TemplateHelper.compile_system_template(
      mjml_content,
      alert_title,
      dgettext("emails_booking_changes", "A meeting changed in your external calendar."),
      intent: @intent,
      eyebrow: dgettext("emails_booking_changes", "Action required"),
      stage_title: alert_title,
      stage_subtitle: stage_subtitle(meeting)
    )
  end

  # A group meeting cannot be moved as a whole (`Tymeslot.Bookings.Reschedule`
  # refuses it), so its copy never asks the organiser to update or reschedule
  # the booking. What they can do instead: move the event back in their own
  # calendar, send every participant a reschedule request, or cancel the
  # meeting from the dashboard.
  defp stage_subtitle(meeting) do
    if Meeting.group?(meeting),
      do: dgettext("emails_booking_changes", "Please review the group meeting in Tymeslot."),
      else:
        dgettext("emails_booking_changes", "Please review and update the booking in Tymeslot.")
  end

  defp alert_parts(:deleted, meeting) do
    title = Sanitise.sanitize_for_email(meeting.title)

    {
      :cancelled,
      dgettext(
        "emails_booking_changes",
        "The meeting \"%{title}\" was deleted from your external calendar. Tymeslot still has this booking on record - please review and cancel it here if the meeting is no longer taking place.",
        title: title
      ),
      dgettext("emails_booking_changes", "Meeting Deleted in External Calendar")
    }
  end

  defp alert_parts(:modified, meeting) do
    title = Sanitise.sanitize_for_email(meeting.title)

    {
      :alert,
      modified_alert_message(meeting, title),
      dgettext("emails_booking_changes", "Meeting Rescheduled in External Calendar")
    }
  end

  defp modified_alert_message(meeting, title) do
    if Meeting.group?(meeting) do
      dgettext(
        "emails_booking_changes",
        "The group meeting \"%{title}\" was rescheduled in your external calendar. Tymeslot still holds the original time for every participant, and a group meeting cannot be moved for everyone at once.",
        title: title
      )
    else
      dgettext(
        "emails_booking_changes",
        "The meeting \"%{title}\" was rescheduled in your external calendar. Tymeslot still holds the original booking - please review the details and update or cancel it accordingly.",
        title: title
      )
    end
  end

  defp explanation_section(:deleted, _meeting) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="1.6">
          #{dgettext("emails_booking_changes", "This meeting was <strong>removed from your external calendar</strong> but is still active in Tymeslot. If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.")}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp explanation_section(:modified, meeting) do
    """
    <mj-section padding="12px 0 0 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="1.6">
          #{modified_explanation_html(meeting)}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp modified_explanation_html(meeting) do
    if Meeting.group?(meeting) do
      dgettext(
        "emails_booking_changes",
        "This group meeting was <strong>rescheduled in your external calendar</strong>. Tymeslot still shows the original time above, and its participants still expect it. To keep the original time, move the event back in your calendar. To change it, send the participants a reschedule request from your dashboard, or cancel the meeting there so every participant is notified."
      )
    else
      dgettext(
        "emails_booking_changes",
        "This meeting was <strong>rescheduled in your external calendar</strong>. Tymeslot still shows the original time above. If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details."
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Plain-text rendering
  # ---------------------------------------------------------------------------

  defp render_text(meeting, {owner_time, time_format}, :deleted, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = view_url(meeting, dashboard_url)
    custom_answers = TextBodyHelper.format_custom_answers(meeting, locale)

    """
    #{dgettext("emails_booking_changes", "Meeting Deleted in External Calendar")}

    #{dgettext("emails_booking_changes", "The meeting \"%{title}\" was deleted from your external calendar but is still active in Tymeslot.", title: meeting.title)}

    #{dgettext("emails_booking_changes", "MEETING DETAILS:")}
    #{dgettext("emails_booking_changes", "Date:")} #{Formatting.format_date(owner_time, locale)}
    #{dgettext("emails_booking_changes", "Time:")} #{Formatting.format_time(owner_time, locale, time_format)}
    #{dgettext("emails_booking_changes", "Duration:")} #{Formatting.format_duration(meeting.duration, locale)}
    #{dgettext("emails_booking_changes", "Location:")} #{meeting.location || dgettext("emails_booking_changes", "Not specified")}
    #{custom_answers}
    #{dgettext("emails_booking_changes", "If the meeting is no longer happening, please cancel it in Tymeslot so the attendee is notified and the time slot is freed up.")}

    #{dgettext("emails_booking_changes", "View meeting:")}
    #{view_url}

    #{dgettext("emails_booking_changes", "This notification was triggered automatically when a change was detected in your external calendar.")}
    """
  end

  defp render_text(meeting, {owner_time, time_format}, :modified, locale) do
    dashboard_url = UrlBuilder.build_url("/dashboard/meetings")
    view_url = view_url(meeting, dashboard_url)
    custom_answers = TextBodyHelper.format_custom_answers(meeting, locale)

    """
    #{dgettext("emails_booking_changes", "Meeting Rescheduled in External Calendar")}

    #{dgettext("emails_booking_changes", "The meeting \"%{title}\" was rescheduled in your external calendar. Tymeslot still holds the original booking shown below.", title: meeting.title)}

    #{dgettext("emails_booking_changes", "ORIGINAL BOOKING DETAILS:")}
    #{dgettext("emails_booking_changes", "Date:")} #{Formatting.format_date(owner_time, locale)}
    #{dgettext("emails_booking_changes", "Time:")} #{Formatting.format_time(owner_time, locale, time_format)}
    #{dgettext("emails_booking_changes", "Duration:")} #{Formatting.format_duration(meeting.duration, locale)}
    #{dgettext("emails_booking_changes", "Location:")} #{meeting.location || dgettext("emails_booking_changes", "Not specified")}
    #{custom_answers}
    #{modified_next_steps_text(meeting)}

    #{dgettext("emails_booking_changes", "View meeting:")}
    #{view_url}

    #{dgettext("emails_booking_changes", "This notification was triggered automatically when a change was detected in your external calendar.")}
    """
  end

  defp modified_next_steps_text(meeting) do
    if Meeting.group?(meeting) do
      dgettext(
        "emails_booking_changes",
        "A group meeting cannot be moved for everyone at once. To keep the original time, move the event back in your calendar. To change it, send the participants a reschedule request from your dashboard, or cancel the meeting there so every participant is notified."
      )
    else
      dgettext(
        "emails_booking_changes",
        "If the new time is final, please update or reschedule the booking in Tymeslot so the attendee receives updated details."
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp email_subject(:deleted, title, date_short),
    do:
      dgettext(
        "emails_booking_changes",
        "Action required: \"%{title}\" was deleted from your external calendar (%{date})",
        title: title,
        date: date_short
      )

  defp email_subject(:modified, title, date_short),
    do:
      dgettext(
        "emails_booking_changes",
        "Action required: \"%{title}\" was rescheduled in your external calendar (%{date})",
        title: title,
        date: date_short
      )

  # Built now, to the host's dashboard view of this booking; the stored
  # `view_url` is a copy from booking time that may name a page that no
  # longer exists.
  defp view_url(%{id: id}, _dashboard_url) when is_binary(id),
    do: MeetingLinks.host_view_url(id)

  defp view_url(_meeting, dashboard_url), do: dashboard_url
end
