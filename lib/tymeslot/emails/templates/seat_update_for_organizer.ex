defmodule Tymeslot.Emails.Templates.SeatUpdateForOrganizer do
  @moduledoc """
  The organiser's email about one seat of a group meeting: a spot was booked,
  a participant cancelled their spot, or a participant moved their spot to
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

  Like every organiser email, it carries no calendar file: the organiser's
  calendar holds the slot as one provider event that Tymeslot keeps up to
  date itself, and an attachment would be imported on top of it as a second
  event by mail servers that process invitations.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :booked | :cancelled | :moved

  @spec render(variant(), String.t(), Tymeslot.Emails.EmailService.appointment_details()) ::
          Swoosh.Email.t()
  def render(variant, organizer_email, details) when variant in [:booked, :cancelled, :moved] do
    details = Formatting.without_location_note(details)
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      intent = intent(variant)
      copy = copy(variant, details)

      mjml_content = """
      #{Text.centered_text(copy.lead, padding: "8px 0 16px 0")}

      #{MeetingComponents.attendee_info_section(intent, attendee_info(details))}

      #{MeetingComponents.attendee_message_box(intent, details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(TemplateHelper.organizer_meeting_details(details), locale)}

      #{MeetingComponents.custom_answers_section(details)}

      #{if line = seats_line(details), do: Text.centered_text(line, font_size: "14px", padding: "8px 0 8px 0")}

      #{Text.section_title(dgettext("emails_booking", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(intent, [%{text: dgettext("emails_booking", "Open in dashboard"), url: details.dashboard_url, style: :primary}])}
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
      |> subject(Sanitise.sanitize_for_header(copy.subject))
      |> html_body(TemplateHelper.compile_template(mjml_content, stage))
      |> text_body(text_body(details, copy, locale))
    end)
  end

  defp intent(:booked), do: :confirmed
  defp intent(:cancelled), do: :cancelled
  defp intent(:moved), do: :alert

  defp copy(:booked, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking", "New booking"),
      title: dgettext("emails_booking", "A spot was booked"),
      lead:
        dgettext("emails_booking", "%{name} booked a spot in your group meeting.", name: name),
      subject:
        dgettext("emails_booking", "Spot booked: %{name} - %{date}",
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
      eyebrow: dgettext("emails_booking", "Cancelled"),
      title: dgettext("emails_booking", "The last participant cancelled their spot"),
      lead:
        dgettext(
          "emails_booking",
          "%{name} cancelled their spot. Nobody is left on this slot, so the meeting has been cancelled and the time is free again.",
          name: name
        ),
      subject:
        dgettext("emails_booking", "Slot freed: %{name} cancelled - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp copy(:cancelled, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking", "Cancelled"),
      title: dgettext("emails_booking", "A participant cancelled their spot"),
      lead:
        dgettext(
          "emails_booking",
          "%{name} cancelled their spot. The meeting goes ahead for everyone else.",
          name: name
        ),
      subject:
        dgettext("emails_booking", "Spot cancelled: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp copy(:moved, details) do
    name = details.attendee_name

    %{
      eyebrow: dgettext("emails_booking", "Rescheduled"),
      title: dgettext("emails_booking", "A participant moved their spot"),
      lead: moved_lead(details) <> old_slot_freed_note(details),
      subject:
        dgettext("emails_booking", "Spot moved: %{name} - %{date}",
          name: name,
          date: short_date(details)
        )
    }
  end

  defp short_date(details),
    do: Formatting.format_date_short(details.date, RecipientLocale.organizer_locale(details))

  # The time the spot moved from is unknown only when its seat row has since
  # gone (see `SeatEmails`), so the sentence then names the new time alone.
  defp moved_lead(%{original_start_time_owner_tz: %DateTime{} = previous} = details) do
    locale = RecipientLocale.organizer_locale(details)

    dgettext("emails_booking", "%{name} moved their spot from %{from} to %{to}.",
      name: details.attendee_name,
      from: Formatting.format_datetime(previous, locale),
      to: Formatting.format_datetime(details.start_time_owner_tz, locale)
    )
  end

  defp moved_lead(details) do
    dgettext("emails_booking", "%{name} moved their spot to %{to}.",
      name: details.attendee_name,
      to:
        Formatting.format_datetime(
          details.start_time_owner_tz,
          RecipientLocale.organizer_locale(details)
        )
    )
  end

  defp old_slot_freed_note(%{old_slot_freed: true}) do
    " " <>
      dgettext(
        "emails_booking",
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
      "emails_booking",
      "%{taken} of %{count} spot taken",
      "%{taken} of %{count} spots taken",
      details.capacity,
      taken: details.seats_taken,
      count: details.capacity
    )
  end

  defp text_body(details, copy, locale) do
    view = TemplateHelper.as_organizer_view(details)

    """
    #{copy.title}

    #{copy.lead}
    #{TextBodyHelper.format_attendee_info(view, locale)}
    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{TextBodyHelper.format_meeting_details(view, locale)}#{TextBodyHelper.format_custom_answers(view, locale)}

    #{seats_line(details)}
    #{dgettext("emails_booking", "Open in dashboard")}: #{details.dashboard_url}
    """
  end
end
