defmodule Tymeslot.Emails.Templates.SeriesRequest do
  @moduledoc """
  The one request a series held for approval sends, in place of a request
  per session: the organiser's (`:organizer`), asking them to approve or
  decline the series, and the booker's (`:attendee`), acknowledging it.

  The organiser's carries what the single `BookingApprovalRequest` carries
  to decide without opening the dashboard (who is asking, their message,
  the deadline after which the request lapses) with every session listed
  in place of the one time, and the same two buttons, which open the review
  page rather than acting on being followed (see
  `Tymeslot.Meetings.ApprovalToken`). The answer is for the whole series.

  The booker's lists the sessions they asked for and says none of them is
  booked until the host answers, and by when they will hear. Neither lists
  per-session links: a session of a held series is not managed on its own.

  With `nudge: true` in the payload, the organiser's is the reminder sent
  halfway to the deadline: the same request, under a reminder's subject.

  The payload is `Tymeslot.Emails.SeriesBuilder`'s for the held sessions,
  with `:approval_urls` (`MeetingLinks.approval_urls/1`),
  `:approval_deadline_at` and `:attendee_message`.
  """

  import Swoosh.Email

  alias Tymeslot.BookingSeries
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    SeriesSessions,
    Styles,
    TemplateHelper,
    Text
  }

  alias Tymeslot.Utils.DateTimeUtils

  use Gettext, backend: TymeslotWeb.Gettext

  @spec render(:attendee | :organizer, String.t(), Tymeslot.Emails.SeriesBuilder.t()) ::
          Swoosh.Email.t()
  def render(:organizer, organizer_email, details) do
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      first = hd(details.sessions)
      rule = rule(details, first.start_time_owner_tz, locale, details[:organizer_time_format])
      deadline = organizer_deadline(details, locale)
      urls = details.approval_urls

      mjml_content = """
      #{MeetingComponents.counterpart_section(:alert, first)}

      #{MeetingComponents.attendee_message_box(:alert, details[:attendee_message])}

      #{if rule, do: Text.centered_text(rule, font_weight: "700", padding: "8px 0 8px 0")}

      #{SeriesSessions.html(details.sessions, :organizer, locale, links: false)}

      #{muted(deadline, "16px 0 16px 0")}

      #{Buttons.action_button(:confirmed, approve_label(), urls.approve_url, full_width: true, size: :large)}
      #{Buttons.action_button(:cancelled, decline_label(), urls.decline_url, full_width: true)}

      #{muted(buttons_note(), "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: :alert,
          eyebrow: organizer_eyebrow(details),
          stage_title: organizer_subject(details),
          stage_subtitle: details.meeting_type
        )

      MjmlEmail.base_email()
      |> to({details.organizer_name, organizer_email})
      |> MjmlEmail.put_reply_to(details.attendee_name, details.attendee_email)
      |> subject(organizer_subject(details))
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(organizer_text(details, rule, deadline, locale))
    end)
  end

  def render(:attendee, attendee_email, details) do
    locale = RecipientLocale.attendee_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      rule = rule(details, hd(details.sessions).start_time_attendee_tz, locale, nil)
      intro = attendee_intro(details, locale)

      mjml_content = """
      #{Text.centered_text(intro, padding: "8px 0 16px 0")}

      #{if rule, do: Text.centered_text(rule, font_weight: "700", padding: "0 0 8px 0")}

      #{SeriesSessions.html(details.sessions, :attendee, locale, links: false)}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: :alert,
          eyebrow: dgettext("emails_booking_series", "Request sent"),
          stage_title: attendee_subject(details),
          stage_subtitle:
            dgettext("emails_booking_series", "%{meeting_type} with %{name}",
              meeting_type: details.meeting_type,
              name: details.organizer_name
            )
        )

      MjmlEmail.base_email()
      |> to({details.attendee_name, attendee_email})
      |> MjmlEmail.put_reply_to(details.organizer_name, details.organizer_email)
      |> subject(attendee_subject(details))
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(attendee_text(details, rule, intro, locale))
    end)
  end

  defp organizer_eyebrow(%{nudge: true}), do: dgettext("emails_booking_series", "Still waiting")
  defp organizer_eyebrow(_details), do: dgettext("emails_booking_series", "Needs your answer")

  defp organizer_subject(%{nudge: true} = details) do
    dngettext(
      "emails_booking_series",
      "Reminder: %{attendee} requests %{count} session",
      "Reminder: %{attendee} requests %{count} sessions",
      details.count,
      attendee: details.attendee_name
    )
  end

  defp organizer_subject(details) do
    dngettext(
      "emails_booking_series",
      "%{attendee} requests %{count} session",
      "%{attendee} requests %{count} sessions",
      details.count,
      attendee: details.attendee_name
    )
  end

  defp attendee_subject(details) do
    dngettext(
      "emails_booking_series",
      "Your request for %{count} session was sent",
      "Your request for %{count} sessions was sent",
      details.count
    )
  end

  defp approve_label, do: dgettext("emails_booking_series", "Approve all sessions")
  defp decline_label, do: dgettext("emails_booking_series", "Decline all sessions")

  defp buttons_note do
    dgettext(
      "emails_booking_series",
      "Both buttons open the request for you to confirm. Your answer applies to every session, and nothing is decided until you choose there."
    )
  end

  defp organizer_deadline(%{approval_deadline_at: %DateTime{} = deadline} = details, locale) do
    zone = hd(details.sessions).start_time_owner_tz.time_zone

    dgettext(
      "emails_booking_series",
      "Every session is held until you answer. If you haven't replied by %{deadline}, the request lapses and %{name} is told the times are free again.",
      deadline: format_deadline(deadline, zone, locale, details[:organizer_time_format]),
      name: details.attendee_name
    )
  end

  defp organizer_deadline(details, _locale) do
    dgettext("emails_booking_series", "Every session stays held for %{name} until you answer.",
      name: details.attendee_name
    )
  end

  defp attendee_intro(%{approval_deadline_at: %DateTime{} = deadline} = details, locale) do
    zone = hd(details.sessions).start_time_attendee_tz.time_zone

    dgettext(
      "emails_booking_series",
      "Hi %{name}, %{host} has your request for the sessions below. They are held for you but not booked until %{host} approves them, and you'll hear either way by %{deadline}.",
      name: details.attendee_name,
      host: details.organizer_name,
      deadline: format_deadline(deadline, zone, locale, nil)
    )
  end

  defp attendee_intro(details, _locale) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, %{host} has your request for the sessions below. They are held for you but not booked until %{host} approves them.",
      name: details.attendee_name,
      host: details.organizer_name
    )
  end

  defp format_deadline(deadline, zone, locale, time_format) do
    deadline
    |> DateTimeUtils.convert_to_timezone(zone)
    |> Formatting.format_datetime(locale, time_format)
  end

  defp rule(details, first_start, locale, time_format) do
    BookingSeries.describe_rule(details.series, locale,
      first_start: first_start,
      time_format: time_format
    )
  end

  defp muted(text, padding) do
    """
    <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="#{padding}">
      #{Sanitise.sanitize_for_email(text)}
    </mj-text>
    """
  end

  defp organizer_text(details, rule, deadline, locale) do
    urls = details.approval_urls

    """
    #{organizer_subject(details)}

    #{details.meeting_type}#{if rule, do: "\n#{rule}"}
    #{details.attendee_name} <#{details.attendee_email}>#{message_line(details[:attendee_message])}

    #{SeriesSessions.text(details.sessions, :organizer, locale, links: false)}

    #{deadline}

    #{approve_label()}:
    #{urls.approve_url}

    #{decline_label()}:
    #{urls.decline_url}

    #{buttons_note()}
    """
  end

  defp message_line(message) when is_binary(message) and message != "",
    do: "\n\n" <> message

  defp message_line(_message), do: ""

  defp attendee_text(details, rule, intro, locale) do
    """
    #{attendee_subject(details)}

    #{intro}

    #{details.meeting_type}#{if rule, do: "\n#{rule}"}

    #{SeriesSessions.text(details.sessions, :attendee, locale, links: false)}

    #{details.organizer_name}
    """
  end
end
