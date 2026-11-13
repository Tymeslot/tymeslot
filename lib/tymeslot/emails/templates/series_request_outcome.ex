defmodule Tymeslot.Emails.Templates.SeriesRequestOutcome do
  @moduledoc """
  Tells the booker their series request will not happen, listing the
  sessions it held: one email for the series, in place of
  `BookingRequestOutcome` per session.

  The two variants mean what they mean for a single request: `:declined`,
  the host said no (their reason quoted back when they gave one), and
  `:expired`, nobody answered in time, worded so as not to say the host
  refused. The organiser is sent nothing, as for a single request: they
  declined it, or let it lapse.

  The payload is `Tymeslot.Emails.SeriesBuilder`'s for the released
  sessions, with `:decline_reason`.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    MjmlEmail,
    Sanitise,
    SeriesSessions,
    Styles,
    TemplateHelper,
    Text,
    Urls
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @spec render(:declined | :expired, String.t(), Tymeslot.Emails.SeriesBuilder.t()) ::
          Swoosh.Email.t()
  def render(variant, attendee_email, details) when variant in [:declined, :expired] do
    locale = RecipientLocale.attendee_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      mjml_content = """
      #{Text.centered_text(intro(variant, details), padding: "8px 0 16px 0")}

      #{reason_block(variant, details)}

      #{SeriesSessions.html(details.sessions, :attendee, locale, links: false)}

      #{Buttons.action_button(:confirmed, dgettext("emails_booking_series", "Book another time"), Urls.get_app_url(), full_width: true)}

      #{Text.system_footer_note(free_note())}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(details,
          intent: :cancelled,
          eyebrow: eyebrow(variant),
          stage_title: subject_line(variant, details),
          stage_subtitle:
            dgettext("emails_booking_series", "%{meeting_type} with %{name}",
              meeting_type: details.meeting_type,
              name: details.organizer_name
            )
        )

      MjmlEmail.base_email()
      |> to({details.attendee_name, attendee_email})
      |> MjmlEmail.put_reply_to(details.organizer_name, details.organizer_email)
      |> subject(subject_line(variant, details))
      |> html_body(TemplateHelper.compile_template(mjml_content, organizer_details))
      |> text_body(text(variant, details, locale))
    end)
  end

  defp subject_line(:declined, details) do
    dngettext(
      "emails_booking_series",
      "Your request for %{count} session was declined",
      "Your request for %{count} sessions was declined",
      details.count
    )
  end

  defp subject_line(:expired, details) do
    dngettext(
      "emails_booking_series",
      "Your request for %{count} session expired",
      "Your request for %{count} sessions expired",
      details.count
    )
  end

  defp eyebrow(:declined), do: dgettext("emails_booking_series", "Not confirmed")
  defp eyebrow(:expired), do: dgettext("emails_booking_series", "No longer held")

  defp intro(:declined, details) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, %{host} can't make the sessions below, so none of them is booked.",
      name: details.attendee_name,
      host: details.organizer_name
    )
  end

  defp intro(:expired, details) do
    dgettext(
      "emails_booking_series",
      "Hi %{name}, your request wasn't answered in time, so the sessions below are no longer held for you.",
      name: details.attendee_name
    )
  end

  defp free_note,
    do: dgettext("emails_booking_series", "These times are available for booking again.")

  defp reason(:declined, %{decline_reason: reason}) when is_binary(reason) and reason != "",
    do: reason

  defp reason(_variant, _details), do: nil

  defp reason_block(variant, details) do
    case reason(variant, details) do
      nil ->
        ""

      reason ->
        """
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" padding="0 0 4px 0">
          #{dgettext("emails_booking_series", "They added:")}
        </mj-text>
        <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" font-style="italic" padding="0 0 16px 16px">
          #{reason |> Sanitise.sanitize_for_email() |> String.replace("\n", "<br/>")}
        </mj-text>
        """
    end
  end

  defp text(variant, details, locale) do
    reason =
      case reason(variant, details) do
        nil -> ""
        reason -> "\n#{dgettext("emails_booking_series", "They added:")}\n#{reason}\n"
      end

    """
    #{subject_line(variant, details)}

    #{intro(variant, details)}
    #{reason}
    #{details.meeting_type}

    #{SeriesSessions.text(details.sessions, :attendee, locale, links: false)}

    #{dgettext("emails_booking_series", "Book another time")}: #{Urls.get_app_url()}

    #{free_note()}

    #{details.organizer_name}
    """
  end
end
