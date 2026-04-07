defmodule Tymeslot.Emails.Templates.EventUpdateNotification do
  @moduledoc """
  Email template for notifying attendees of calendar event updates from the dashboard.

  Sent when an organiser edits an existing event (title, time, location, description).
  Includes a highlighted change summary and an updated ICS attachment with SEQUENCE=1.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TextBodyHelper
  }

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Builds an event update notification email for a calendar event attendee.

  ## Parameters

    - `attendee_email` — recipient email address (string)
    - `details` — map with event details:
      - `:event_title` — current event title
      - `:event_uid` — stable UID used across invitations
      - `:start_time` — updated start time (`DateTime`)
      - `:end_time` — updated end time (`DateTime`)
      - `:date` — event date (`Date`)
      - `:duration` — duration in minutes
      - `:location` — location string or nil
      - `:description` — description string or nil
      - `:organizer_name` — organiser display name
      - `:organizer_email` — organiser email address
      - `:changes` — list of `{field, old_value, new_value}` tuples
      - `:attendee_locale` — optional locale string (default: `"en"`)
  """
  @spec update_notification_email(String.t(), map()) :: Swoosh.Email.t()
  def update_notification_email(attendee_email, details) do
    locale = Map.get(details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details = %{
        date: details.date,
        start_time: details.start_time,
        duration: details.duration,
        location: details.location,
        location_type: if(details.location, do: :in_person),
        meeting_type: details.event_title
      }

      changes_html = build_changes_html(details.changes)

      mjml_content = """
      #{Components.title_section(dgettext("emails", "Event Updated"),
      emoji: "📝",
      subtitle: dgettext("emails", "%{name} has updated an event you're attending.", name: details.organizer_name),
      align: "left")}

      #{Components.meeting_details_table(meeting_details, locale)}

      <mj-section padding="0 24px 16px">
        <mj-column>
          <mj-text padding="0">
            <div style="background-color: #fffbeb; border-left: 4px solid #f59e0b; padding: 12px 16px; border-radius: 4px;">
              <p style="margin: 0 0 8px; font-weight: bold; color: #92400e;">#{dgettext("emails", "What Changed")}</p>
              #{changes_html}
            </div>
          </mj-text>
        </mj-column>
      </mj-section>
      """

      details_for_organizer = Map.put_new(details, :organizer_title, nil)
      organizer_details = TemplateHelper.build_organizer_details(details_for_organizer)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = SharedHelpers.format_date_short(details.date, locale)

      ics_details = %{
        title: details.event_title,
        start_time: details.start_time,
        end_time: details.end_time,
        uid: details.event_uid,
        location: details.location,
        description: details.description,
        organizer_name: details.organizer_name,
        organizer_email: details.organizer_email,
        attendee_email: attendee_email
      }

      MjmlEmail.base_email()
      |> to(attendee_email)
      |> subject(
        dgettext("emails", "Updated: %{title} — %{date}",
          title: details.event_title,
          date: date_short
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(details, locale))
      |> attachment(
        IcsGenerator.generate_ics_update_attachment(
          ics_details,
          1,
          locale,
          "update-#{details.event_uid}.ics"
        )
      )
    end)
  end

  defp build_changes_html(changes) do
    changes
    |> Enum.map(&change_to_html/1)
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp change_to_html({:title, from, to}) do
    from_safe = escape(from)
    to_safe = escape(to)

    "<p style=\"margin: 4px 0;\"><strong>#{dgettext("emails", "Title:")}</strong> #{from_safe} → #{to_safe}</p>"
  end

  defp change_to_html({:location, from, to}) do
    from_safe = escape(from)
    to_safe = escape(to)

    "<p style=\"margin: 4px 0;\"><strong>#{dgettext("emails", "Location:")}</strong> #{from_safe} → #{to_safe}</p>"
  end

  defp change_to_html({:description, _from, _to}) do
    "<p style=\"margin: 4px 0;\">#{dgettext("emails", "Description updated")}</p>"
  end

  defp change_to_html({:time, from_start, to_start}) do
    from_safe = escape(format_time_short(from_start))
    to_safe = escape(format_time_short(to_start))

    "<p style=\"margin: 4px 0;\"><strong>#{dgettext("emails", "Time:")}</strong> #{from_safe} → #{to_safe}</p>"
  end

  defp change_to_html(_other), do: nil

  defp escape(nil), do: dgettext("emails", "(none)")
  defp escape(val), do: val |> to_string() |> SharedHelpers.sanitize_for_email()

  defp format_time_short(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y, %H:%M UTC")
  defp format_time_short(val), do: to_string(val)

  defp build_text_body(details, locale) do
    changes_text = TextBodyHelper.format_event_changes(details.changes, locale)

    """
    #{dgettext("emails", "Event Updated")}

    #{dgettext("emails", "%{name} has updated an event you're attending.", name: details.organizer_name)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{TextBodyHelper.format_meeting_details(%{date: details.date, start_time: details.start_time, duration: details.duration, location: details.location, meeting_type: details.event_title}, locale)}

    #{dgettext("emails", "What Changed")}
    #{changes_text}

    #{details.organizer_name}
    """
  end
end
