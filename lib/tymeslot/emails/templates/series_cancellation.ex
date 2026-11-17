defmodule Tymeslot.Emails.Templates.SeriesCancellation do
  @moduledoc """
  One email for several sessions of a series cancelled at once ("cancel all
  remaining"), in place of a cancellation per session: the booker's
  (`:attendee`) and the organiser's (`:organizer`).

  The payload is `Tymeslot.Emails.SeriesBuilder`'s for the cancelled
  sessions, with `:cancelled_by` (`:attendee` or `:organizer`) saying who
  cancelled them, which decides the wording. Both list the sessions without
  links (`Tymeslot.Emails.Shared.SeriesSessions`). The booker's copy carries
  one calendar file cancelling each of them on its own UID, one revision
  above its invitation, as `AppointmentCancellation` does for one meeting;
  the organiser's carries none.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Buttons,
    MjmlEmail,
    SeriesSessions,
    TemplateHelper,
    Text,
    Urls
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(:attendee | :organizer, String.t(), Tymeslot.Emails.SeriesBuilder.t()) ::
          Swoosh.Email.t()
  def render(:attendee, attendee_email, details) do
    locale = RecipientLocale.attendee_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      mjml_content = """
      #{Text.centered_text(attendee_intro(details), padding: "8px 0 16px 0")}

      #{SeriesSessions.html(details.sessions, :attendee, locale, links: false)}

      #{Text.centered_text(dgettext("emails_booking_series", "Would you like to book another time?"), padding: "24px 0 10px 0")}
      #{Buttons.action_button(:confirmed, dgettext("emails_booking_series", "Book another time"), booking_url(details), full_width: true)}

      #{Text.system_footer_note(calendar_note())}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: @intent,
          eyebrow: dgettext("emails_booking_series", "Cancelled"),
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
      |> text_body(attendee_text(details, locale))
      |> attachment(
        IcsGenerator.generate_series_cancel_attachment(
          details.sessions,
          locale,
          "series-#{details.series.uid}.ics"
        )
      )
    end)
  end

  def render(:organizer, organizer_email, details) do
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      mjml_content = """
      #{Text.centered_text(organizer_intro(details), padding: "8px 0 16px 0")}

      #{SeriesSessions.html(details.sessions, :organizer, locale, links: false)}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: @intent,
          eyebrow: dgettext("emails_booking_series", "Cancelled"),
          stage_title: organizer_subject(details),
          stage_subtitle: details.meeting_type
        )

      MjmlEmail.base_email()
      |> to({details.organizer_name, organizer_email})
      |> MjmlEmail.put_reply_to(details.attendee_name, details.attendee_email)
      |> subject(organizer_subject(details))
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(organizer_text(details, locale))
    end)
  end

  defp attendee_subject(details) do
    dngettext(
      "emails_booking_series",
      "%{count} session cancelled",
      "%{count} sessions cancelled",
      details.count
    )
  end

  defp organizer_subject(%{cancelled_by: :organizer} = details) do
    dngettext(
      "emails_booking_series",
      "You cancelled %{count} session with %{attendee}",
      "You cancelled %{count} sessions with %{attendee}",
      details.count,
      attendee: details.attendee_name
    )
  end

  defp organizer_subject(details) do
    dngettext(
      "emails_booking_series",
      "%{attendee} cancelled %{count} session",
      "%{attendee} cancelled %{count} sessions",
      details.count,
      attendee: details.attendee_name
    )
  end

  defp attendee_intro(%{cancelled_by: :organizer} = details) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, I'm sorry, but I've had to cancel the sessions below.",
      name: details.attendee_name
    )
  end

  defp attendee_intro(details) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, the sessions below are cancelled, as you asked. There is nothing more you need to do.",
      name: details.attendee_name
    )
  end

  defp organizer_intro(%{cancelled_by: :organizer} = details) do
    dgettext(
      "emails_booking_series",
      "You cancelled the sessions below. %{attendee} has been told.",
      attendee: details.attendee_name
    )
  end

  defp organizer_intro(details) do
    dgettext(
      "emails_booking_series",
      "%{attendee} cancelled the sessions below.",
      attendee: details.attendee_name
    )
  end

  defp calendar_note do
    dgettext(
      "emails_booking_series",
      "If you added these sessions to your calendar, the attached file removes them there."
    )
  end

  # Built from the host's page now; a payload without one falls back to the
  # app root, so the button is never empty.
  defp booking_url(details) do
    Map.get(hd(details.sessions), :booking_url) || Urls.get_app_url()
  end

  defp attendee_text(details, locale) do
    """
    #{attendee_subject(details)}

    #{attendee_intro(details)}

    #{details.meeting_type}

    #{SeriesSessions.text(details.sessions, :attendee, locale, links: false)}

    #{dgettext("emails_booking_series", "Would you like to book another time?")}
    #{booking_url(details)}

    #{calendar_note()}

    #{details.organizer_name}
    """
  end

  defp organizer_text(details, locale) do
    """
    #{organizer_subject(details)}

    #{organizer_intro(details)}

    #{details.meeting_type}

    #{SeriesSessions.text(details.sessions, :organizer, locale, links: false)}
    """
  end
end
