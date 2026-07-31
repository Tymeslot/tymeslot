defmodule Tymeslot.Emails.Templates.AppointmentConfirmation do
  @moduledoc """
  Email template for appointment confirmations sent to attendees and organisers.
  Role-dispatched via `render/3`.

  The money sections live in the sibling
  `Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks`, which owns
  both the attendee receipt and the organiser payout summary.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Locales

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
          "emails",
          "Hi %{name} - I've blocked the time on my calendar and I'm looking forward to our meeting.",
          name: appointment_details.attendee_name
        )

      payment_receipt = PaymentBlocks.attendee_receipt(appointment_details)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails", "Ready to join when it's time?"),
        button_text: dgettext("emails", "Join Video Meeting"))
      end}

      #{if payment_receipt, do: PaymentBlocks.attendee_receipt_html(payment_receipt)}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{if appointment_details.organizer_contact_info do
        Text.centered_text(dgettext("emails", "Questions? %{contact_info}", contact_info: appointment_details.organizer_contact_info), font_size: "14px", padding: "16px 0 0 0")
      end}

      #{if appointment_details.reminders_summary do
        Callouts.alert_box(@intent, appointment_details.reminders_summary, title: dgettext("emails", "Reminders Scheduled"))
      end}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Confirmed"),
          stage_title: dgettext("emails", "You're booked."),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Appointment Confirmed - %{date} with %{name}",
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

      intro_copy =
        dgettext(
          "emails",
          "Hi %{guest} - %{booker} has invited you as a guest to this meeting with %{organizer}.",
          guest: guest_name,
          booker: appointment_details.attendee_name,
          organizer: appointment_details.organizer_name
        )

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{if guest_video_url do
        MeetingComponents.video_meeting_section(@intent, guest_video_url,
        title: dgettext("emails", "Join when you're ready"),
        button_text: dgettext("emails", "Join Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Will you be there?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Yes, I'll attend"), url: Map.get(appointment_details, :guest_accept_url, "#"), style: :secondary}, %{text: dgettext("emails", "Can't make it"), url: Map.get(appointment_details, :guest_decline_url, "#"), style: :danger}])}

      #{Text.centered_text(dgettext("emails", "You can change your response any time using the buttons above."), font_size: "14px", padding: "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "You're invited"),
          stage_title: dgettext("emails", "You've been added as a guest"),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)
      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "You're invited - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_guest_text_body(appointment_details, guest_name, locale))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
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

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type}, organizer_locale(appointment_details))}

      #{if organizer_video_url do
        MeetingComponents.video_meeting_section(@intent, organizer_video_url,
        title: dgettext("emails", "Host video call"),
        button_text: dgettext("emails", "Start Meeting"))
      end}

      #{MeetingComponents.custom_answers_section(appointment_details)}
      #{if organiser_payment, do: PaymentBlocks.organizer_summary_html(organiser_payment)}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "New booking"),
          stage_title: dgettext("emails", "New Appointment Booked!"),
          stage_subtitle:
            dgettext("emails", "%{name} has scheduled a meeting with you.",
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
          dgettext("emails", "New Appointment: %{name} - %{date}",
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
    #{dgettext("emails", "Appointment Confirmed!")}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "I'm looking forward to our meeting. I've blocked the time on my calendar and will be ready for you.")}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}
    #{action_links}#{payment_section}
    #{if appointment_details.organizer_contact_info, do: "\n#{dgettext("emails", "QUESTIONS?")}\n#{appointment_details.organizer_contact_info}\n"}
    #{if appointment_details.reminders_summary, do: "\n#{appointment_details.reminders_summary}\n", else: ""}

    #{dgettext("emails", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_guest_text_body(appointment_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(join_url(:guest, appointment_details), locale)

    """
    #{dgettext("emails", "You're invited!")}

    #{dgettext("emails", "Hi %{guest},", guest: guest_name)}

    #{dgettext("emails", "%{booker} has invited you as a guest to this meeting with %{organizer}.", booker: appointment_details.attendee_name, organizer: appointment_details.organizer_name)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}

    #{dgettext("emails", "WILL YOU BE THERE?")}
    #{dgettext("emails", "Yes, I'll attend: %{url}", url: Map.get(appointment_details, :guest_accept_url, "#"))}
    #{dgettext("emails", "Can't make it: %{url}", url: Map.get(appointment_details, :guest_decline_url, "#"))}

    #{dgettext("emails", "You can change your response any time using the links above.")}
    """
  end

  defp build_organizer_text_body(appointment_details, organiser_payment) do
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
    #{dgettext("emails", "New Appointment Booked!")}

    #{dgettext("emails", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name)}#{attendee_info}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}#{action_links}#{payment_section}

    #{dgettext("emails", "PREPARATION REMINDERS:")}
    #{dgettext("emails", "- Review any relevant materials")}
    #{dgettext("emails", "- Prepare an agenda if needed")}
    #{dgettext("emails", "- Test video/audio setup if virtual")}
    #{organizer_reminder_line(appointment_details)}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_reminder_line(appointment_details) do
    if Map.get(appointment_details, :reminders_enabled) != false do
      reminder_time = format_reminder_for_organizer(appointment_details)
      dgettext("emails", "- Set a reminder %{time} before", time: reminder_time)
    else
      dgettext("emails", "- No reminder emails are scheduled for this appointment")
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
        dgettext("emails", "15 minutes")
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
  #     so they get the shared room URL, the same link the ICS attachment on
  #     this very email already advertises.
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

  defp join_url(:guest, details), do: Map.get(details, :meeting_url)

  defp organizer_locale(_appointment_details), do: Locales.default_locale()
end
