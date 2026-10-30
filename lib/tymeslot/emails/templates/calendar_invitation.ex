defmodule Tymeslot.Emails.Templates.CalendarInvitation do
  @moduledoc """
  Email template for calendar event invitations sent from the dashboard calendar.

  Simpler than booking confirmations — no reschedule/cancel URLs or reminders.
  Includes event details, how a series repeats (`:recurrence_rule`, stated
  in the body only), the description, the event's video
  link (`:video_link`) as a join section when it has one, and an ICS calendar
  attachment (see `Tymeslot.Emails.Shared.CalendarEventContent`).

  An all-day event (`all_day: true`) carries `:start_date`, an exclusive
  `:end_date` and an inclusive `:last_date` instead of `:start_time`,
  `:end_time` and `:duration`; the body then shows its days rather than a
  clock time, and the attachment uses date-only DTSTART/DTEND.

  ## Cancellations

  `method: :cancel` renders the cancellation of the event instead, sent when
  the organiser deletes it or removes the recipient from it: the same
  details, headed as cancelled, with an attachment that marks the entry
  cancelled at `:sequence` and states no join link. `series: true` says that
  every occurrence of a recurring event is cancelled; the details shown are
  then those of the occurrence the organiser deleted it from. `removed: true`
  says the recipient was taken off an event that still takes place, rather
  than that it was cancelled. Either way the email tells the recipient to
  delete the entry themselves where their calendar does not.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    CalendarEventContent,
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    TemplateHelper,
    TextBodyHelper
  }

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Builds an invitation email for a calendar event.

  ## Parameters

    - `attendee_email` — recipient email address (string)
    - `invitation_details` — map with event details (see module docs)
  """
  @spec render(String.t(), map()) :: Swoosh.Email.t()
  def render(attendee_email, invitation_details) do
    locale = RecipientLocale.attendee_locale(invitation_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details = CalendarEventContent.hero_details(invitation_details)
      video_link = CalendarEventContent.join_link(invitation_details)
      copy = copy(invitation_details, locale)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{CalendarEventContent.body_sections(invitation_details, copy.intent)}

      #{MeetingComponents.video_meeting_section(:confirmed, video_link)}

      #{removal_hint_html(invitation_details)}
      """

      details_for_organizer =
        Map.put_new(invitation_details, :organizer_title, nil)

      organizer_details =
        TemplateHelper.build_organizer_details(details_for_organizer,
          intent: copy.intent,
          eyebrow: copy.eyebrow,
          stage_title: copy.title,
          stage_subtitle: copy.subtitle
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      ics_details = CalendarEventContent.ics_details(invitation_details, attendee_email)

      MjmlEmail.base_email()
      |> CalendarEventContent.from_organiser(invitation_details)
      |> to(attendee_email)
      |> MjmlEmail.put_reply_to(
        invitation_details.organizer_name,
        invitation_details.organizer_email
      )
      |> subject(copy.subject)
      |> html_body(html_body)
      |> text_body(build_text_body(invitation_details, meeting_details, video_link, copy, locale))
      |> attachment(build_ics_attachment(ics_details, invitation_details, locale))
    end)
  end

  defp cancellation?(details), do: CalendarEventContent.cancellation?(details)

  # The attachment cancels the entry, but Gmail and Outlook do not always
  # apply a published cancellation on their own.
  defp removal_hint(details) do
    if cancellation?(details),
      do:
        dgettext(
          "emails",
          "If the event is still in your calendar, you can delete it there."
        )
  end

  defp removal_hint_html(details) do
    case removal_hint(details) do
      nil -> ""
      hint -> Callouts.alert_box(:cancelled, hint)
    end
  end

  # What the email calls itself: an invitation, the recipient's removal from
  # an event, the cancellation of one event, or of a whole series.
  defp copy(details, locale) do
    date_short = Formatting.format_date_short(details.date, locale)
    name = details.organizer_name
    title = details.event_title

    cond do
      not cancellation?(details) ->
        %{
          intent: :confirmed,
          eyebrow: dgettext("emails", "Invited"),
          title: dgettext("emails", "You're Invited"),
          subtitle: dgettext("emails", "%{name} has invited you to an event.", name: name),
          subject:
            dgettext("emails", "Calendar Invitation - %{title} on %{date}",
              title: title,
              date: date_short
            )
        }

      Map.get(details, :removed) == true ->
        %{
          intent: :cancelled,
          eyebrow: dgettext("emails", "Removed"),
          title: dgettext("emails", "Removed from Event"),
          subtitle: dgettext("emails", "%{name} has removed you from an event.", name: name),
          subject:
            dgettext("emails", "Removed from %{title} on %{date}", title: title, date: date_short)
        }

      Map.get(details, :series) == true ->
        %{
          intent: :cancelled,
          eyebrow: dgettext("emails", "Cancelled"),
          title: dgettext("emails", "Event Cancelled"),
          subtitle:
            dgettext(
              "emails",
              "%{name} has cancelled a recurring event you were invited to. Every occurrence is cancelled.",
              name: name
            ),
          subject: dgettext("emails", "Cancelled - %{title} (every occurrence)", title: title)
        }

      true ->
        %{
          intent: :cancelled,
          eyebrow: dgettext("emails", "Cancelled"),
          title: dgettext("emails", "Event Cancelled"),
          subtitle:
            dgettext("emails", "%{name} has cancelled an event you were invited to.", name: name),
          subject:
            dgettext("emails", "Cancelled - %{title} on %{date}", title: title, date: date_short)
        }
    end
  end

  defp build_ics_attachment(ics_details, details, locale) do
    if cancellation?(details) do
      IcsGenerator.generate_ics_cancel_attachment(
        ics_details,
        Map.get(details, :sequence) || 0,
        locale,
        "cancellation-#{details.event_uid}.ics"
      )
    else
      IcsGenerator.generate_ics_attachment(
        ics_details,
        locale,
        "invitation-#{details.event_uid}.ics"
      )
    end
  end

  defp build_text_body(invitation_details, meeting_details, video_link, copy, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)

    """
    #{copy.title}

    #{copy.subtitle}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}
    #{CalendarEventContent.text_sections(invitation_details)}
    #{TextBodyHelper.format_video_section(video_link, locale)}
    #{removal_hint(invitation_details)}

    #{invitation_details.organizer_name}
    """
  end
end
