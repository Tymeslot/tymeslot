defmodule Tymeslot.Emails.Templates.CalendarInvitation do
  @moduledoc """
  Email template for calendar event invitations sent from the dashboard calendar.

  Simpler than booking confirmations — no reschedule/cancel URLs, video sections,
  or reminders. Includes event details and an ICS calendar attachment.

  An all-day event (`all_day: true`) carries `:start_date`, an exclusive
  `:end_date` and an inclusive `:last_date` instead of `:start_time`,
  `:end_time` and `:duration`; the body then shows its days rather than a
  clock time, and the attachment uses date-only DTSTART/DTEND.

  ## Cancellations

  `method: :cancel` renders the cancellation of the event instead, sent when
  the organiser deletes it or removes the recipient from it: the same
  details, headed as cancelled, with an attachment that marks the entry
  cancelled at `:sequence`. `series: true` says that every occurrence of a
  recurring event is cancelled; the details shown are then those of the
  occurrence the organiser deleted it from.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
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
    locale = Map.get(invitation_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details =
        invitation_details
        |> Map.take([:all_day, :last_date])
        |> Map.merge(%{
          date: invitation_details.date,
          start_time: invitation_details.start_time,
          duration: invitation_details.duration,
          location: invitation_details.location,
          location_type: if(invitation_details.location, do: :in_person),
          meeting_type: invitation_details.event_title
        })

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}
      """

      details_for_organizer =
        Map.put_new(invitation_details, :organizer_title, nil)

      copy = copy(invitation_details, locale)

      organizer_details =
        TemplateHelper.build_organizer_details(details_for_organizer,
          intent: copy.intent,
          eyebrow: copy.eyebrow,
          stage_title: copy.title,
          stage_subtitle: copy.subtitle
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      ics_details = %{
        all_day: Map.get(invitation_details, :all_day, false),
        start_date: Map.get(invitation_details, :start_date),
        end_date: Map.get(invitation_details, :end_date),
        title: invitation_details.event_title,
        start_time: invitation_details.start_time,
        end_time: invitation_details.end_time,
        uid: invitation_details.event_uid,
        location: invitation_details.location,
        description: invitation_details.description,
        organizer_name: invitation_details.organizer_name,
        organizer_email: invitation_details.organizer_email,
        attendee_email: attendee_email
      }

      MjmlEmail.base_email()
      |> to(attendee_email)
      |> subject(Sanitise.sanitize_for_header(copy.subject))
      |> html_body(html_body)
      |> text_body(build_text_body(invitation_details, copy, locale))
      |> attachment(build_ics_attachment(ics_details, invitation_details, locale))
    end)
  end

  defp cancellation?(details), do: Map.get(details, :method) == :cancel

  # What the email calls itself: an invitation, the cancellation of one
  # event, or the cancellation of a whole series.
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

  defp build_text_body(invitation_details, copy, locale) do
    text_details =
      invitation_details
      |> Map.take([:all_day, :last_date])
      |> Map.merge(%{
        date: invitation_details.date,
        start_time: invitation_details.start_time,
        duration: invitation_details.duration,
        location: invitation_details.location,
        meeting_type: invitation_details.event_title
      })

    meeting_details = TextBodyHelper.format_meeting_details(text_details, locale)

    """
    #{copy.title}

    #{copy.subtitle}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}

    #{invitation_details.organizer_name}
    """
  end
end
