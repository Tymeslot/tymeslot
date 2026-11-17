defmodule Tymeslot.Emails.Templates.SeriesConfirmation do
  @moduledoc """
  The one confirmation a booked series sends, in place of a confirmation per
  session: the booker's (`:attendee`) and the organiser's (`:organizer`),
  role-dispatched by `render/3` as `AppointmentConfirmation` is.

  Both list every session (`Tymeslot.Emails.Shared.SeriesSessions`) with the
  rhythm of a recurring series above them, numbered by their place in the
  series and counted as the series is: a session cancelled before the
  confirmation went out is shown cancelled, not left out, so "Your 4
  sessions" lists four. The booker's copy carries each
  session's own reschedule and cancel links, a link to the page managing
  them all, and one calendar file with every session in it. The organiser's
  links each session in their dashboard and carries no calendar file, for
  the reason `AppointmentConfirmation` gives.

  The payload is `Tymeslot.Emails.SeriesBuilder`'s.
  """

  import Swoosh.Email

  alias Tymeslot.BookingSeries
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    SeriesSessions,
    TemplateHelper,
    Text
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

  @spec render(:attendee | :organizer, String.t(), Tymeslot.Emails.SeriesBuilder.t()) ::
          Swoosh.Email.t()
  def render(:attendee, attendee_email, details) do
    locale = RecipientLocale.attendee_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      rule = attendee_rule(details, locale)
      total = total(details)

      mjml_content = """
      #{Text.centered_text(attendee_intro(details), padding: "8px 0 16px 0")}

      #{if rule, do: Text.centered_text(rule, font_weight: "700", padding: "0 0 8px 0")}

      #{SeriesSessions.html(details.sessions, :attendee, locale)}

      #{if total, do: Text.centered_text(total, font_size: "15px", padding: "16px 0 0 0")}

      #{Buttons.action_button(@intent, dgettext("emails_booking_series", "Manage all sessions"), details.series_url, full_width: true)}

      #{Text.system_footer_note(dgettext("emails_booking_series", "The attached calendar file adds every session to your calendar."))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: @intent,
          eyebrow: dgettext("emails_booking_series", "Confirmed"),
          stage_title: sessions_booked(details.count),
          stage_subtitle:
            dgettext("emails_booking_series", "%{meeting_type} with %{name}",
              meeting_type: details.meeting_type,
              name: details.organizer_name
            )
        )

      MjmlEmail.base_email()
      |> to({details.attendee_name, attendee_email})
      |> MjmlEmail.put_reply_to(details.organizer_name, details.organizer_email)
      |> subject(
        dngettext(
          "emails_booking_series",
          "Your %{count} session with %{host} is booked",
          "Your %{count} sessions with %{host} are booked",
          details.count,
          host: details.organizer_name
        )
      )
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(attendee_text(details, rule, total, locale))
      |> attachment(
        IcsGenerator.generate_series_attachment(
          Enum.reject(details.sessions, &Map.get(&1, :cancelled, false)),
          locale,
          "series-#{details.series.uid}.ics"
        )
      )
    end)
  end

  def render(:organizer, organizer_email, details) do
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      rule = organizer_rule(details, locale)
      total = total(details)

      mjml_content = """
      #{MeetingComponents.counterpart_section(@intent, hd(details.sessions))}

      #{if rule, do: Text.centered_text(rule, font_weight: "700", padding: "8px 0 8px 0")}

      #{SeriesSessions.html(details.sessions, :organizer, locale)}

      #{if total, do: Text.centered_text(total, font_size: "15px", padding: "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: @intent,
          eyebrow: dgettext("emails_booking_series", "New series"),
          stage_title: organizer_headline(details),
          stage_subtitle: details.meeting_type
        )

      # No calendar file: the organiser's calendar holds each session as an
      # event Tymeslot writes itself (see `AppointmentConfirmation`).
      MjmlEmail.base_email()
      |> to({details.organizer_name, organizer_email})
      |> MjmlEmail.put_reply_to(details.attendee_name, details.attendee_email)
      |> subject(organizer_headline(details))
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(organizer_text(details, rule, total, locale))
    end)
  end

  defp attendee_intro(details) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, your sessions are booked. Each one has its own links below, in case one of them needs to move.",
      name: details.attendee_name
    )
  end

  defp sessions_booked(count) do
    dngettext(
      "emails_booking_series",
      "%{count} session booked",
      "%{count} sessions booked",
      count
    )
  end

  defp organizer_headline(details) do
    dngettext(
      "emails_booking_series",
      "%{attendee} booked %{count} session",
      "%{attendee} booked %{count} sessions",
      details.count,
      attendee: details.attendee_name
    )
  end

  defp attendee_rule(details, locale) do
    BookingSeries.describe_rule(details.series, locale,
      first_start: hd(details.sessions).start_time_attendee_tz
    )
  end

  defp organizer_rule(details, locale) do
    BookingSeries.describe_rule(details.series, locale,
      first_start: hd(details.sessions).start_time_owner_tz,
      time_format: Map.get(details, :organizer_time_format)
    )
  end

  defp total(%{total: %{cents: cents, currency: currency}}) do
    dgettext("emails_booking_series", "Total paid: %{amount}",
      amount: Formatting.format_currency(cents, currency)
    )
  end

  defp total(_details), do: nil

  defp attendee_text(details, rule, total, locale) do
    """
    #{sessions_booked(details.count)}

    #{attendee_intro(details)}

    #{details.meeting_type}#{if rule, do: "\n#{rule}"}

    #{SeriesSessions.text(details.sessions, :attendee, locale)}
    #{if total, do: "\n#{total}\n"}#{manage_line(details.series_url)}
    #{dgettext("emails_booking_series", "The attached calendar file adds every session to your calendar.")}

    #{details.organizer_name}
    """
  end

  defp manage_line(url) when is_binary(url),
    do: "\n#{dgettext("emails_booking_series", "Manage all sessions")}: #{url}\n"

  defp manage_line(_url), do: ""

  defp organizer_text(details, rule, total, locale) do
    """
    #{organizer_headline(details)}

    #{details.meeting_type}#{if rule, do: "\n#{rule}"}
    #{details.attendee_name} <#{details.attendee_email}>

    #{SeriesSessions.text(details.sessions, :organizer, locale)}
    #{if total, do: "\n#{total}\n"}
    """
  end
end
