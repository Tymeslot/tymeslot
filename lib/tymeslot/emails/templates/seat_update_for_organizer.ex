defmodule Tymeslot.Emails.Templates.SeatUpdateForOrganizer do
  @moduledoc """
  The organiser's email about one seat of a group meeting: a spot was booked,
  a spot was taken on a slot the organiser was told had been cancelled, a
  participant cancelled their spot, or a participant moved their spot to
  another time.

  The solo templates cannot say any of this. They are about *the* booking: a
  seat leaving is not "the appointment has been cancelled" (everyone else is
  still coming), and the organiser needs to know how full the slot now is.
  The payload is `Tymeslot.Emails.AppointmentBuilder.for_organizer_of_seat/2`:
  the participant's own details, the slot's `:seats_taken` and `:capacity`,
  and `:dashboard_url` in place of any booking link, because the public
  links to manage a booking are refused for a group meeting and the
  participant's seat links are theirs alone. A move also carries
  `:original_start_time_owner_tz`, the time the spot moved from.

  When the seat was paid for (`:booking_payment` in the payload), the booked
  email adds what the organiser received (`PaymentBlocks`), and the cancelled
  one says the money is still theirs to refund (`RefundNotice`): a participant
  leaving refunds nothing on its own.

  Like every organiser email, it carries no calendar file: the organiser's
  calendar holds the slot as one provider event that Tymeslot keeps up to
  date itself, and an attachment would be imported on top of it as a second
  event by mail servers that process invitations.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.AppointmentCancellation.RefundNotice
  alias Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :booked | :revived | :cancelled | :moved

  @spec render(variant(), String.t(), Tymeslot.Emails.EmailService.appointment_details()) ::
          Swoosh.Email.t()
  def render(variant, organizer_email, details)
      when variant in [:booked, :revived, :cancelled, :moved] do
    details = Formatting.without_location_note(details)
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      intent = intent(variant)
      copy = copy(variant, details)
      meeting_details = TemplateHelper.organizer_meeting_details(details)
      payment = payment_block(variant, details)

      mjml_content = """
      #{Text.centered_text(copy.lead, padding: "8px 0 16px 0")}

      #{MeetingComponents.attendee_info_section(intent, attendee_info(details))}

      #{MeetingComponents.attendee_message_box(intent, details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(details)}

      #{payment.html}

      #{if line = seats_line(details), do: Text.centered_text(line, font_size: "14px", padding: "8px 0 8px 0")}

      #{Text.section_title(dgettext("emails_booking_changes", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(intent, [%{text: dgettext("emails_booking_changes", "Open in dashboard"), url: details.dashboard_url, style: :primary}])}
      """

      stage =
        TemplateHelper.build_organizer_details(details,
          intent: intent,
          eyebrow: copy.eyebrow,
          stage_title: copy.title,
          stage_subtitle: details.meeting_type || ""
        )

      MjmlEmail.base_email()
      |> to({details.organizer_name, organizer_email})
      |> MjmlEmail.put_reply_to(details.attendee_name, details.attendee_email)
      |> subject(copy.subject)
      |> html_body(TemplateHelper.compile_template(mjml_content, stage))
      |> text_body(text_body(details, meeting_details, copy, locale, payment.text))
    end)
  end

  # What the money did, for a seat that was paid for: the payout when the
  # spot is booked, the balance still held when it is cancelled. Nothing for a
  # free seat or a move (the seat keeps its payment).
  defp payment_block(:booked, details) do
    case PaymentBlocks.organizer_summary(details) do
      nil ->
        %{html: "", text: ""}

      summary ->
        %{
          html: PaymentBlocks.organizer_summary_html(summary),
          text: "\n" <> PaymentBlocks.organizer_summary_text(summary) <> "\n"
        }
    end
  end

  defp payment_block(:cancelled, details) do
    notice = RefundNotice.build(details)
    %{html: RefundNotice.html(notice), text: RefundNotice.text(notice)}
  end

  defp payment_block(variant, _details) when variant in [:moved, :revived],
    do: %{html: "", text: ""}

  defp intent(:booked), do: :confirmed
  defp intent(:revived), do: :confirmed
  defp intent(:cancelled), do: :cancelled
  defp intent(:moved), do: :alert

  defp copy(:booked, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "New booking"),
      title: dgettext("emails_booking_changes", "A spot was booked"),
      lead:
        dgettext("emails_booking_changes", "%{name} booked a spot in your group meeting.",
          name: name
        ),
      subject:
        dgettext("emails_booking_changes", "Spot booked: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  # A seat on a slot held again after its last confirmed seat left: the
  # organiser was told the meeting had been cancelled (the `slot_held`
  # cancellation below), so this says first that it is on again.
  defp copy(:revived, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "Back on"),
      title: dgettext("emails_booking_changes", "Your group meeting is on again"),
      lead:
        dgettext(
          "emails_booking_changes",
          "%{name} took a spot on this slot, so the meeting you were told had been cancelled goes ahead after all.",
          name: name
        ),
      subject:
        dgettext("emails_booking_changes", "Meeting back on: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  # The last confirmed seat, beside seats still awaiting their bookers' email
  # verification: the meeting is off for the organiser, but the held seats
  # still occupy the time, so it is not called free. The organiser never sees
  # a held seat, so nothing more is said of them.
  defp copy(:cancelled, %{slot_held: true} = details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "Cancelled"),
      title: dgettext("emails_booking_changes", "The last participant cancelled their spot"),
      lead:
        dgettext(
          "emails_booking_changes",
          "%{name} cancelled their spot. No one else has confirmed a spot on this slot, so the meeting has been cancelled.",
          name: name
        ),
      subject:
        dgettext("emails_booking_changes", "Meeting cancelled: %{name} cancelled - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  # The last seat: its leaving cancelled the meeting. This is the organiser's
  # only email about it, so it says both facts.
  defp copy(:cancelled, %{slot_freed: true} = details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "Cancelled"),
      title: dgettext("emails_booking_changes", "The last participant cancelled their spot"),
      lead:
        dgettext(
          "emails_booking_changes",
          "%{name} cancelled their spot. Nobody is left on this slot, so the meeting has been cancelled and the time is free again.",
          name: name
        ),
      subject:
        dgettext("emails_booking_changes", "Slot freed: %{name} cancelled - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp copy(:cancelled, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "Cancelled"),
      title: dgettext("emails_booking_changes", "A participant cancelled their spot"),
      lead:
        dgettext(
          "emails_booking_changes",
          "%{name} cancelled their spot. The meeting goes ahead for everyone else.",
          name: name
        ),
      subject:
        dgettext("emails_booking_changes", "Spot cancelled: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp copy(:moved, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking_changes", "Rescheduled"),
      title: dgettext("emails_booking_changes", "A participant moved their spot"),
      lead: moved_lead(details) <> old_slot_freed_note(details),
      subject:
        dgettext("emails_booking_changes", "Spot moved: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp short_date(details),
    do:
      Formatting.format_date_short(
        TemplateHelper.organizer_meeting_details(details).date,
        RecipientLocale.organizer_locale(details)
      )

  # The time the spot moved from is unknown only when its seat row has since
  # gone (see `SeatEmails`), so the sentence then names the new time alone.
  defp moved_lead(%{original_start_time_owner_tz: %DateTime{} = previous} = details) do
    locale = RecipientLocale.organizer_locale(details)

    time_format = Map.get(details, :organizer_time_format)

    dgettext("emails_booking_changes", "%{name} moved their spot from %{from} to %{to}.",
      name: details.attendee_name,
      from: Formatting.format_datetime(previous, locale, time_format),
      to: Formatting.format_datetime(details.start_time_owner_tz, locale, time_format)
    )
  end

  defp moved_lead(details) do
    dgettext("emails_booking_changes", "%{name} moved their spot to %{to}.",
      name: details.attendee_name,
      to:
        Formatting.format_datetime(
          details.start_time_owner_tz,
          RecipientLocale.organizer_locale(details),
          Map.get(details, :organizer_time_format)
        )
    )
  end

  # As for a cancellation (`copy/2`): held seats keep the earlier time
  # occupied, so it is not called free.
  defp old_slot_freed_note(%{old_slot_held: true}) do
    " " <>
      dgettext(
        "emails_booking_changes",
        "No one else has confirmed a spot at the earlier time, so that meeting has been cancelled."
      )
  end

  defp old_slot_freed_note(%{old_slot_freed: true}) do
    " " <>
      dgettext(
        "emails_booking_changes",
        "Nobody is left at the earlier time, so that meeting has been cancelled and the time is free again."
      )
  end

  defp old_slot_freed_note(_details), do: ""

  defp attendee_info(details) do
    %{
      name: details.attendee_name,
      email: details.attendee_email,
      phone: details[:attendee_phone],
      company: details[:attendee_company]
    }
  end

  # How full the slot is now, guests included: each guest takes a seat. A
  # slot the last seat has just left has no count worth stating.
  defp seats_line(%{slot_freed: true}), do: nil

  defp seats_line(details) do
    dngettext(
      "emails_booking_changes",
      "%{taken} of %{count} spot taken",
      "%{taken} of %{count} spots taken",
      details.capacity,
      taken: details.seats_taken,
      count: details.capacity
    )
  end

  defp text_body(details, meeting_details, copy, locale, payment_text) do
    """
    #{copy.title}

    #{copy.lead}
    #{TextBodyHelper.format_attendee_info(details, locale)}
    #{dgettext("emails_booking_changes", "MEETING DETAILS:")}
    #{TextBodyHelper.format_meeting_details(meeting_details, locale)}#{TextBodyHelper.format_custom_answers(details, locale)}#{payment_text}

    #{seats_line(details)}
    #{dgettext("emails_booking_changes", "Open in dashboard")}: #{details.dashboard_url}
    """
  end
end
