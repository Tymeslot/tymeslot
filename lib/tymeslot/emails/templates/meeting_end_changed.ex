defmodule Tymeslot.Emails.Templates.MeetingEndChanged do
  @moduledoc """
  Email template for a booking whose end the host moved in their own
  calendar: it still starts when it did, and now ends at another time.
  Role-dispatched via `render/3`.

  Sent by `Tymeslot.Notifications.Email.EndChangeEmails` to the
  booker or each group participant (`:attendee`, the meeting as that person
  sees it) and to each guest (`:guest`). Both state the new end beside the
  one it replaces, read in the recipient's zone, and attach an updated
  calendar entry at the meeting's advanced `ical_sequence`, so the entry
  already in their calendar is replaced rather than duplicated.

  Nobody is asked to answer again: the start did not move, so a guest's
  earlier answer still stands.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Callouts,
    Formatting,
    JoinUrl,
    MeetingComponents,
    MjmlEmail,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :alert

  @spec render(:attendee | :guest, String.t(), Tymeslot.Emails.EmailService.appointment_details()) ::
          Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      {to, from} = end_times(appointment_details, locale)

      intro =
        dgettext(
          "emails_booking",
          "Hi %{name} - our meeting now ends at %{to} instead of %{from}. It still starts at the same time, and my calendar is already updated.",
          name: appointment_details.attendee_name,
          to: to,
          from: from
        )

      email(
        {appointment_details.attendee_name, attendee_email},
        :attendee,
        appointment_details,
        locale,
        {intro, JoinUrl.for(:attendee, appointment_details)}
      )
    end)
  end

  def render(:guest, guest_email, appointment_details) do
    # Guests inherit the booker's locale, as their invitation does.
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      {to, from} = end_times(appointment_details, locale)
      guest_name = Map.get(appointment_details, :guest_name) || guest_email

      intro =
        dgettext(
          "emails_booking",
          "Hi %{guest} - the meeting with %{organizer} now ends at %{to} instead of %{from}. It still starts at the same time, so your answer stands.",
          guest: guest_name,
          organizer: appointment_details.organizer_name,
          to: to,
          from: from
        )

      guest_video_url = JoinUrl.for(:guest, appointment_details)

      email(
        {guest_name, guest_email},
        :guest,
        # The calendar entry advertises the guests' link, as the email does.
        Map.put(appointment_details, :meeting_url, guest_video_url),
        locale,
        {intro, guest_video_url}
      )
    end)
  end

  defp email(recipient, audience, appointment_details, locale, {intro, video_url}) do
    {to, from} = end_times(appointment_details, locale)

    meeting_details = TemplateHelper.attendee_meeting_details(appointment_details, audience)

    mjml_content = """
    #{Text.centered_text(intro, padding: "8px 0 16px 0")}

    #{Callouts.alert_box(@intent, from, title: dgettext("emails_booking", "Previously ended at"))}

    #{MeetingComponents.meeting_details_table(meeting_details, locale)}

    #{if video_url do
      MeetingComponents.video_meeting_section(@intent, video_url,
      title: dgettext("emails_booking", "Same link, new end time"),
      button_text: dgettext("emails_booking", "Join Meeting"))
    end}
    """

    header =
      TemplateHelper.build_organizer_details(appointment_details,
        intent: @intent,
        eyebrow: dgettext("emails_booking", "New end time"),
        stage_title: dgettext("emails_booking", "The meeting now ends at %{time}.", time: to),
        stage_subtitle:
          dgettext("emails_booking", "Meeting with %{name}",
            name: appointment_details.organizer_name
          )
      )

    subject =
      dgettext("emails_booking", "New end time - %{date} with %{name}",
        date: Formatting.format_date_short(meeting_details.date, locale),
        name: appointment_details.organizer_name
      )

    MjmlEmail.base_email()
    |> to(recipient)
    |> subject(subject)
    |> html_body(TemplateHelper.compile_template(mjml_content, header))
    |> text_body(
      text_body(appointment_details, meeting_details, intro, {to, from}, video_url, locale)
    )
    |> attachment(
      IcsGenerator.generate_ics_update_attachment(
        appointment_details,
        Map.get(appointment_details, :ical_sequence) || 0,
        locale,
        "appointment-#{appointment_details.uid}.ics"
      )
    )
  end

  # Both ends in the recipient's zone, the one the start is shown in. An end
  # on a later day than the start says which day.
  defp end_times(appointment_details, locale) do
    start = appointment_details.start_time_attendee_tz
    zone = start.time_zone

    {end_label(DateTime.shift_zone!(appointment_details.end_time, zone), start, locale),
     end_label(DateTime.shift_zone!(appointment_details.original_end_time, zone), start, locale)}
  end

  defp end_label(finish, start, locale) do
    if Date.compare(DateTime.to_date(finish), DateTime.to_date(start)) == :eq,
      do: Formatting.format_time(finish, locale),
      else: Formatting.format_datetime(finish, locale)
  end

  defp text_body(appointment_details, meeting_details, intro, {to, from}, video_url, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)
    video_section = TextBodyHelper.format_video_section(video_url, locale)

    """
    #{dgettext("emails_booking", "The meeting now ends at %{time}.", time: to)}

    #{intro}

    #{dgettext("emails_booking", "Previously ended at")}: #{from}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}
    #{appointment_details.organizer_name}
    """
  end
end
