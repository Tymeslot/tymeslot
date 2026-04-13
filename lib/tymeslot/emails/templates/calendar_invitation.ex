defmodule Tymeslot.Emails.Templates.CalendarInvitation do
  @moduledoc """
  Email template for calendar event invitations sent from the dashboard calendar.

  Simpler than booking confirmations — no reschedule/cancel URLs, video sections,
  or reminders. Includes event details and an ICS calendar attachment.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    TemplateHelper,
    TextBodyHelper
  }

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

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
      meeting_details = %{
        date: invitation_details.date,
        start_time: invitation_details.start_time,
        duration: invitation_details.duration,
        location: invitation_details.location,
        location_type: if(invitation_details.location, do: :in_person),
        meeting_type: invitation_details.event_title
      }

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}
      """

      details_for_organizer =
        Map.put_new(invitation_details, :organizer_title, nil)

      organizer_details =
        TemplateHelper.build_organizer_details(details_for_organizer,
          intent: @intent,
          eyebrow: dgettext("emails", "Invited"),
          stage_title: dgettext("emails", "You're Invited"),
          stage_subtitle:
            dgettext("emails", "%{name} has invited you to an event.",
              name: invitation_details.organizer_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(invitation_details.date, locale)

      ics_details = %{
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
      |> subject(
        dgettext("emails", "Calendar Invitation - %{title} on %{date}",
          title: invitation_details.event_title,
          date: date_short
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(invitation_details, locale))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          ics_details,
          locale,
          "invitation-#{invitation_details.event_uid}.ics"
        )
      )
    end)
  end

  defp build_text_body(invitation_details, locale) do
    text_details = %{
      date: invitation_details.date,
      start_time: invitation_details.start_time,
      duration: invitation_details.duration,
      location: invitation_details.location,
      meeting_type: invitation_details.event_title
    }

    meeting_details = TextBodyHelper.format_meeting_details(text_details, locale)

    """
    #{dgettext("emails", "You're Invited")}

    #{dgettext("emails", "%{name} has invited you to an event.", name: invitation_details.organizer_name)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}

    #{invitation_details.organizer_name}
    """
  end
end
