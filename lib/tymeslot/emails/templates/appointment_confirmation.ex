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
    GroupSession,
    JoinUrl,
    MeetingComponents,
    MjmlEmail,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  # A confirmation email announces a positive outcome — the booking is set.
  @intent :confirmed

  # The organiser reminder line's lead time when the payload names none.
  @default_organizer_reminder %{value: 15, unit: "minutes"}

  @spec render(
          :attendee | :organizer | :guest,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_video_url = JoinUrl.for(:attendee, appointment_details)

      meeting_details = TemplateHelper.attendee_meeting_details(appointment_details, :attendee)

      intro_copy =
        dgettext(
          "emails_booking",
          "Hi %{name} - I've blocked the time on my calendar and I'm looking forward to our meeting.",
          name: appointment_details.attendee_name
        )

      payment_receipt = PaymentBlocks.attendee_receipt(appointment_details)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{if line = GroupSession.line(appointment_details), do: Text.centered_text(line, font_size: "14px", padding: "0 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.organizer_note_box(@intent, appointment_details[:organizer_note])}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails_booking", "Ready to join when it's time?"),
        button_text: dgettext("emails_booking", "Join Video Meeting"))
      end}

      #{if payment_receipt, do: PaymentBlocks.attendee_receipt_html(payment_receipt)}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Need to make changes?"), [%{text: dgettext("emails_booking", "Reschedule"), url: Map.get(appointment_details, :reschedule_url), style: :secondary}, %{text: dgettext("emails_booking", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url), style: :danger}])}

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

      date_short = Formatting.format_date_short(meeting_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> MjmlEmail.put_reply_to(
        appointment_details.organizer_name,
        appointment_details.organizer_email
      )
      |> subject(
        dgettext("emails_booking", "Appointment Confirmed - %{date} with %{name}",
          date: date_short,
          name: appointment_details.organizer_name
        )
      )
      |> html_body(html_body)
      |> text_body(
        build_attendee_text_body(appointment_details, meeting_details, locale, payment_receipt)
      )
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
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      guest_name = Map.get(appointment_details, :guest_name) || guest_email
      guest_video_url = JoinUrl.for(:guest, appointment_details)

      meeting_details = TemplateHelper.attendee_meeting_details(appointment_details, :guest)

      intro_copy = guest_intro(appointment_details, guest_name)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.organizer_note_box(@intent, appointment_details[:organizer_note])}

      #{if guest_video_url do
        MeetingComponents.video_meeting_section(@intent, guest_video_url,
        title: dgettext("emails_booking", "Join when you're ready"),
        button_text: dgettext("emails_booking", "Join Meeting"))
      end}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Will you be there?"), TemplateHelper.guest_answer_actions(appointment_details), footer: dgettext("emails_booking", "You can change your response any time using the buttons above."))}
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
      date_short = Formatting.format_date_short(meeting_details.date, locale)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> MjmlEmail.put_reply_to(
        appointment_details.organizer_name,
        appointment_details.organizer_email
      )
      |> subject(
        dgettext("emails_booking", "You're invited - %{date} with %{name}",
          date: date_short,
          name: appointment_details.organizer_name
        )
      )
      |> html_body(html_body)
      |> text_body(
        build_guest_text_body(appointment_details, meeting_details, guest_name, locale)
      )
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
      organizer_video_url = JoinUrl.for(:organizer, appointment_details)
      meeting_details = TemplateHelper.organizer_meeting_details(appointment_details)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(meeting_details, organizer_locale(appointment_details))}

      #{if organizer_video_url do
        MeetingComponents.video_meeting_section(@intent, organizer_video_url,
        title: dgettext("emails_booking", "Host video call"),
        button_text: dgettext("emails_booking", "Start Meeting"))
      end}

      #{MeetingComponents.custom_answers_section(appointment_details)}
      #{if organiser_payment, do: PaymentBlocks.organizer_summary_html(organiser_payment)}

      #{Text.section_title(dgettext("emails_booking", "Preparation reminders"))}
      #{Text.bullet_list(organizer_prep_items(appointment_details))}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Need to make changes?"), [%{text: dgettext("emails_booking", "Reschedule"), url: Map.get(appointment_details, :reschedule_url), style: :secondary}, %{text: dgettext("emails_booking", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url), style: :danger}])}
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
      |> MjmlEmail.put_reply_to(
        appointment_details.attendee_name,
        appointment_details.attendee_email
      )
      |> subject(
        dgettext("emails_booking", "New Appointment: %{name} - %{date}",
          name: appointment_details.attendee_name,
          date:
            Formatting.format_date_short(
              meeting_details.date,
              organizer_locale(appointment_details)
            )
        )
      )
      |> html_body(html_body)
      |> text_body(
        build_organizer_text_body(appointment_details, meeting_details, organiser_payment)
      )
    end)
  end

  defp build_attendee_text_body(appointment_details, meeting_details, locale, payment_receipt) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)

    video_section =
      TextBodyHelper.format_video_section(JoinUrl.for(:attendee, appointment_details), locale)

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

    #{GroupSession.text(appointment_details)}#{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organizer_note(appointment_details, locale)}#{video_section}#{custom_answers}
    #{action_links}#{payment_section}
    #{if appointment_details.organizer_contact_info, do: "\n#{dgettext("emails_booking", "QUESTIONS?")}\n#{appointment_details.organizer_contact_info}\n"}
    #{if appointment_details.reminders_summary, do: "\n#{appointment_details.reminders_summary}\n", else: ""}

    #{dgettext("emails_booking", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end

  # Whoever put the guest on the meeting is the one named as inviting them:
  # the booker for a guest brought on the public page, the host for one they
  # added themselves (see `Tymeslot.Meetings.GuestSchema.inviter/1`).
  defp guest_intro(%{guest_invited_by: :organizer} = appointment_details, guest_name) do
    dgettext(
      "emails_booking",
      "Hi %{guest} - %{organizer} has invited you as a guest to this meeting.",
      guest: guest_name,
      organizer: appointment_details.organizer_name
    )
  end

  defp guest_intro(appointment_details, guest_name) do
    dgettext(
      "emails_booking",
      "Hi %{guest} - %{booker} has invited you as a guest to this meeting with %{organizer}.",
      guest: guest_name,
      booker: appointment_details.attendee_name,
      organizer: appointment_details.organizer_name
    )
  end

  defp guest_invited_line(%{guest_invited_by: :organizer} = appointment_details) do
    dgettext("emails_booking", "%{organizer} has invited you as a guest to this meeting.",
      organizer: appointment_details.organizer_name
    )
  end

  defp guest_invited_line(appointment_details) do
    dgettext(
      "emails_booking",
      "%{booker} has invited you as a guest to this meeting with %{organizer}.",
      booker: appointment_details.attendee_name,
      organizer: appointment_details.organizer_name
    )
  end

  defp build_guest_text_body(appointment_details, meeting_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)

    video_section =
      TextBodyHelper.format_video_section(JoinUrl.for(:guest, appointment_details), locale)

    """
    #{dgettext("emails_booking", "You're invited!")}

    #{dgettext("emails_booking", "Hi %{guest},", guest: guest_name)}

    #{guest_invited_line(appointment_details)}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organizer_note(appointment_details, locale)}#{video_section}#{TextBodyHelper.format_guest_answers(appointment_details, dgettext("emails_booking", "WILL YOU BE THERE?"), dgettext("emails_booking", "You can change your response any time using the links above."))}
    """
  end

  defp build_organizer_text_body(appointment_details, meeting_details, organiser_payment) do
    meeting_details =
      TextBodyHelper.format_meeting_details(
        meeting_details,
        organizer_locale(appointment_details)
      )

    attendee_info =
      TextBodyHelper.format_attendee_info(
        appointment_details,
        organizer_locale(appointment_details)
      )

    video_section =
      TextBodyHelper.format_video_section(
        JoinUrl.for(:organizer, appointment_details),
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
    #{TextBodyHelper.format_bullets(organizer_prep_items(appointment_details))}

    #{dgettext("emails_booking", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  @doc """
  The organiser's preparation reminders, in their locale: the one list both
  the HTML and the plain-text body of their confirmation render.
  """
  @spec organizer_prep_items(Tymeslot.Emails.EmailService.appointment_details()) :: [
          String.t()
        ]
  def organizer_prep_items(appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      [
        dgettext("emails_booking", "Review any relevant materials"),
        dgettext("emails_booking", "Prepare an agenda if needed"),
        dgettext("emails_booking", "Test video/audio setup if virtual"),
        organizer_reminder_item(appointment_details)
      ]
    end)
  end

  defp organizer_reminder_item(appointment_details) do
    if Map.get(appointment_details, :reminders_enabled) != false do
      reminder_time = format_reminder_for_organizer(appointment_details)
      dgettext("emails_booking", "Set a reminder %{time} before", time: reminder_time)
    else
      dgettext("emails_booking", "No reminder emails are scheduled for this appointment")
    end
  end

  # The reminder's lead time in the organiser's locale, in the form the
  # "before" sentence takes ("1 Tag", "1 годину"), not a duration's ("24
  # Stunden", "1 година"), and never the attendee's pre-localised string. A
  # payload without one reads as the 15 minutes it always has.
  defp format_reminder_for_organizer(appointment_details) do
    raw =
      case Map.get(appointment_details, :reminder_raw) do
        %{value: _value, unit: _unit} = raw -> raw
        _other -> @default_organizer_reminder
      end

    Formatting.format_reminder_label(raw, organizer_locale(appointment_details))
  end

  defp organizer_locale(appointment_details),
    do: RecipientLocale.organizer_locale(appointment_details)
end
