defmodule Tymeslot.Emails.Templates.AppointmentConfirmation do
  @moduledoc """
  Email template for appointment confirmations sent to attendees and organisers.
  Role-dispatched via `render/3`.

  The money sections live in the sibling
  `Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks`, which owns
  both the attendee receipt and the organiser payout summary.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  # A confirmation email announces a positive outcome — the booking is set.
  @intent :confirmed

  @spec render(
          :attendee | :organizer | :guest,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_video_url = join_url(:attendee, appointment_details)

      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type
      }

      intro_copy =
        dgettext(
          "emails_booking",
          "Hi %{name} - I've blocked the time on my calendar and I'm looking forward to our meeting.",
          name: appointment_details.attendee_name
        )

      payment_receipt = PaymentBlocks.attendee_receipt(appointment_details)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{organiser_note(appointment_details)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails_booking", "Ready to join when it's time?"),
        button_text: dgettext("emails_booking", "Join Video Meeting"))
      end}

      #{if payment_receipt, do: PaymentBlocks.attendee_receipt_html(payment_receipt)}

      #{Text.section_title(dgettext("emails_booking", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails_booking", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails_booking", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{if appointment_details.organizer_contact_info do
        Text.centered_text(dgettext("emails_booking", "Questions? %{contact_info}", contact_info: appointment_details.organizer_contact_info), font_size: "14px", padding: "16px 0 0 0")
      end}

      #{if appointment_details.reminders_summary do
        Callouts.alert_box(@intent, appointment_details.reminders_summary, title: dgettext("emails_booking", "Reminders Scheduled"))
      end}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Confirmed"),
          stage_title: dgettext("emails_booking", "You're booked."),
          stage_subtitle:
            dgettext("emails_booking", "Meeting with %{name}",
              name: appointment_details.organizer_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "Appointment Confirmed - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, locale, payment_receipt))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
          locale,
          "appointment-#{appointment_details.uid}.ics"
        )
      )
    end)
  end

  def render(:guest, guest_email, appointment_details) do
    # Guests have no per-guest locale field; they intentionally inherit the
    # booker's locale (`:attendee_locale`) set when the booking was created.
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      guest_name = Map.get(appointment_details, :guest_name) || guest_email
      guest_video_url = join_url(:guest, appointment_details)

      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type
      }

      intro_copy = guest_intro(appointment_details, guest_name)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{organiser_note(appointment_details)}

      #{if guest_video_url do
        MeetingComponents.video_meeting_section(@intent, guest_video_url,
        title: dgettext("emails_booking", "Join when you're ready"),
        button_text: dgettext("emails_booking", "Join Meeting"))
      end}

      #{Text.section_title(dgettext("emails_booking", "Will you be there?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails_booking", "Yes, I'll attend"), url: Map.get(appointment_details, :guest_accept_url, "#"), style: :secondary}, %{text: dgettext("emails_booking", "Can't make it"), url: Map.get(appointment_details, :guest_decline_url, "#"), style: :danger}])}

      #{Text.centered_text(dgettext("emails_booking", "You can change your response any time using the buttons above."), font_size: "14px", padding: "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "You're invited"),
          stage_title: dgettext("emails_booking", "You've been added as a guest"),
          stage_subtitle:
            dgettext("emails_booking", "Meeting with %{name}",
              name: appointment_details.organizer_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)
      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "You're invited - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_guest_text_body(appointment_details, guest_name, locale))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          # The calendar entry is where a guest is most likely to click from,
          # so it advertises the same link the email body does rather than the
          # bare room URL. Where there is no guests' link the value is the
          # room URL already, so this never changes a non-video booking.
          Map.put(appointment_details, :meeting_url, guest_video_url),
          locale,
          "appointment-#{appointment_details.uid}.ics"
        )
      )
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      organiser_payment = PaymentBlocks.organizer_summary(appointment_details)
      organizer_video_url = join_url(:organizer, appointment_details)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message], appointment_details[:message_from] || :attendee)}

      #{MeetingComponents.meeting_details_table(TemplateHelper.organizer_meeting_details(appointment_details), organizer_locale(appointment_details))}

      #{if organizer_video_url do
        MeetingComponents.video_meeting_section(@intent, organizer_video_url,
        title: dgettext("emails_booking", "Host video call"),
        button_text: dgettext("emails_booking", "Start Meeting"))
      end}

      #{MeetingComponents.custom_answers_section(appointment_details)}
      #{if organiser_payment, do: PaymentBlocks.organizer_summary_html(organiser_payment)}

      #{Text.section_title(dgettext("emails_booking", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails_booking", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails_booking", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "New booking"),
          stage_title: dgettext("emails_booking", "New Appointment Booked!"),
          stage_subtitle:
            dgettext("emails_booking", "%{name} has scheduled a meeting with you.",
              name: appointment_details.attendee_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      # No ICS attachment for the organiser email. The organiser is the
      # calendar owner — Tymeslot already writes the event straight to their
      # CalDAV/OAuth calendar. An iTIP `METHOD:REQUEST` attachment on top of
      # that causes iMIP-aware mail servers (Zimbra, Exchange, iCloud Mail)
      # to auto-import the ICS as if it were an external invitation,
      # producing a duplicate event and re-sending invites to the attendee.
      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "New Appointment: %{name} - %{date}",
            name: appointment_details.attendee_name,
            date:
              Formatting.format_date_short(
                appointment_details.date,
                organizer_locale(appointment_details)
              )
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_organizer_text_body(appointment_details, organiser_payment))
    end)
  end

  # Who did the inviting. On a booking made through a booking page it is the
  # person who booked, and the meeting is with the host. On one the host
  # created themselves it is the other way round — naming the main guest as the
  # one who invited everybody describes a booking that never happened.
  defp guest_intro(details, guest_name \\ nil) do
    host_created? = details[:message_from] == :organiser

    {inviter, other} =
      if host_created?,
        do: {details.organizer_name, details.attendee_name},
        else: {details.attendee_name, details.organizer_name}

    case guest_name do
      nil ->
        dgettext(
          "emails_booking",
          "%{booker} has invited you as a guest to this meeting with %{organizer}.",
          booker: inviter,
          organizer: other
        )

      name ->
        dgettext(
          "emails_booking",
          "Hi %{guest} - %{booker} has invited you as a guest to this meeting with %{organizer}.",
          guest: name,
          booker: inviter,
          organizer: other
        )
    end
  end

  # What the host wrote when creating the meeting, shown to the people they
  # invited. A note left by the person *booking* is not echoed back to them —
  # it goes to the organiser, which `render(:organizer, …)` already does.
  defp organiser_note(appointment_details) do
    case appointment_details[:message_from] do
      :organiser ->
        MeetingComponents.attendee_message_box(
          @intent,
          appointment_details[:attendee_message],
          :organiser
        )

      _attendee ->
        ""
    end
  end

  defp build_attendee_text_body(appointment_details, locale, payment_receipt) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(join_url(:attendee, appointment_details), locale)

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    payment_section =
      case payment_receipt do
        nil -> ""
        receipt -> "\n#{PaymentBlocks.attendee_receipt_text(receipt)}\n"
      end

    """
    #{dgettext("emails_booking", "Appointment Confirmed!")}

    #{dgettext("emails_booking", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "I'm looking forward to our meeting. I've blocked the time on my calendar and will be ready for you.")}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organiser_note(appointment_details, locale)}#{video_section}#{custom_answers}
    #{action_links}#{payment_section}
    #{if appointment_details.organizer_contact_info, do: "\n#{dgettext("emails_booking", "QUESTIONS?")}\n#{appointment_details.organizer_contact_info}\n"}
    #{if appointment_details.reminders_summary, do: "\n#{appointment_details.reminders_summary}\n", else: ""}

    #{dgettext("emails_booking", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_guest_text_body(appointment_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(join_url(:guest, appointment_details), locale)

    """
    #{dgettext("emails_booking", "You're invited!")}

    #{dgettext("emails_booking", "Hi %{guest},", guest: guest_name)}

    #{guest_intro(appointment_details)}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organiser_note(appointment_details, locale)}#{video_section}

    #{dgettext("emails_booking", "WILL YOU BE THERE?")}
    #{dgettext("emails_booking", "Yes, I'll attend: %{url}", url: Map.get(appointment_details, :guest_accept_url, "#"))}
    #{dgettext("emails_booking", "Can't make it: %{url}", url: Map.get(appointment_details, :guest_decline_url, "#"))}

    #{dgettext("emails_booking", "You can change your response any time using the links above.")}
    """
  end

  defp build_organizer_text_body(appointment_details, organiser_payment) do
    appointment_details = TemplateHelper.as_organizer_view(appointment_details)

    meeting_details =
      TextBodyHelper.format_meeting_details(
        appointment_details,
        organizer_locale(appointment_details)
      )

    attendee_info =
      TextBodyHelper.format_attendee_info(
        appointment_details,
        organizer_locale(appointment_details)
      )

    video_section =
      TextBodyHelper.format_video_section(
        join_url(:organizer, appointment_details),
        organizer_locale(appointment_details)
      )

    action_links =
      TextBodyHelper.format_action_links(
        appointment_details,
        organizer_locale(appointment_details)
      )

    custom_answers =
      TextBodyHelper.format_custom_answers(
        appointment_details,
        organizer_locale(appointment_details)
      )

    payment_section =
      case organiser_payment do
        nil -> ""
        payment -> "\n#{PaymentBlocks.organizer_summary_text(payment)}\n"
      end

    """
    #{dgettext("emails_booking", "New Appointment Booked!")}

    #{dgettext("emails_booking", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name)}#{attendee_info}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}#{action_links}#{payment_section}

    #{dgettext("emails_booking", "PREPARATION REMINDERS:")}
    #{dgettext("emails_booking", "- Review any relevant materials")}
    #{dgettext("emails_booking", "- Prepare an agenda if needed")}
    #{dgettext("emails_booking", "- Test video/audio setup if virtual")}
    #{organizer_reminder_line(appointment_details)}

    #{dgettext("emails_booking", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_reminder_line(appointment_details) do
    if Map.get(appointment_details, :reminders_enabled) != false do
      reminder_time = format_reminder_for_organizer(appointment_details)
      dgettext("emails_booking", "- Set a reminder %{time} before", time: reminder_time)
    else
      dgettext("emails_booking", "- No reminder emails are scheduled for this appointment")
    end
  end

  # Format reminder time in organizer's locale, avoiding pre-localized attendee strings
  defp format_reminder_for_organizer(appointment_details) do
    case Map.get(appointment_details, :reminder_raw) do
      %{value: value, unit: unit} ->
        Formatting.format_duration(
          reminder_to_minutes(value, unit),
          organizer_locale(appointment_details)
        )

      _other ->
        dgettext("emails_booking", "15 minutes")
    end
  end

  defp reminder_to_minutes(value, "hours"), do: value * 60
  defp reminder_to_minutes(value, "days"), do: value * 60 * 24
  defp reminder_to_minutes(value, _unit), do: value

  # Which video join URL each recipient is given.
  #
  # `Meetings.VideoRooms` mints two per-role join URLs when it provisions a
  # room: `organizer_video_url` (provider role "organizer") and
  # `attendee_video_url` (provider role "participant"). Each is built from that
  # one person's name and email, so it identifies them in the room.
  # `meeting_url` is the shared, identity-free room URL.
  #
  #   * the organiser hosts the call, so they get the host URL;
  #   * the booker gets the participant URL minted for them;
  #   * guests are third parties with no URL of their own. Handing them the
  #     booker's URL would put them in the room under the booker's identity,
  #     so they get `guest_video_url`, the link
  #     `Meetings.VideoRooms.guest_join_url/1` builds for a recipient the room
  #     cannot name. On most providers that is the shared room URL, the same
  #     link the ICS attachment on this very email already advertises; on one
  #     whose links carry a credential it is that room URL with a token that
  #     names nobody and confers no moderator rights, because a server
  #     enforcing tokens refuses the bare URL outright.
  #
  # The organiser URL falls back to the room URL: a meeting can carry
  # `meeting_url` without the per-role pair (its presence is also what marks a
  # booking as a video meeting; `AppointmentBuilder` derives
  # `location_type: :video` from it), and the host reaching the room beats no
  # join link at all.
  defp join_url(:organizer, details) do
    Map.get(details, :organizer_video_url) || Map.get(details, :meeting_url)
  end

  defp join_url(:attendee, details), do: Map.get(details, :attendee_video_url)

  # The guest URL falls back to the room URL for the same reason the organiser
  # one does: a payload assembled before `guest_video_url` existed, or by a
  # caller that builds its own map, still has a room to point at.
  defp join_url(:guest, details) do
    Map.get(details, :guest_video_url) || Map.get(details, :meeting_url)
  end

  defp organizer_locale(appointment_details),
    do: RecipientLocale.organizer_locale(appointment_details)
end
