defmodule Tymeslot.Emails.Templates.EventUpdateNotification do
  @moduledoc """
  Email template for notifying attendees of calendar event updates from the dashboard.

  Sent when an organiser edits an existing event (title, time, location, description).
  Includes a highlighted change summary and an updated ICS attachment with SEQUENCE=1.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    TextBodyHelper
  }

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :confirmed

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
  @spec render(String.t(), map()) :: Swoosh.Email.t()
  def render(attendee_email, details) do
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

      changes_table = build_changes_table(details.changes)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{changes_table}
      """

      details_for_organizer = Map.put_new(details, :organizer_title, nil)

      organizer_details =
        TemplateHelper.build_organizer_details(details_for_organizer,
          intent: @intent,
          eyebrow: dgettext("emails", "Updated"),
          stage_title: dgettext("emails", "Event updated"),
          stage_subtitle:
            dgettext("emails", "%{name} has updated an event you're attending.",
              name: details.organizer_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(details.date, locale)

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
        Sanitise.sanitize_for_header(
          dgettext("emails", "Updated: %{title} - %{date}",
            title: details.event_title,
            date: date_short
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(details, locale))
      |> attachment(build_ics_attachment(ics_details, details, locale))
    end)
  end

  defp build_ics_attachment(ics_details, details, locale) do
    method = Map.get(details, :method, :request)
    sequence = Map.get(details, :sequence)
    filename = "update-#{details.event_uid}.ics"

    case method do
      :cancel ->
        IcsGenerator.generate_ics_cancel_attachment(
          ics_details,
          sequence || 0,
          locale,
          filename
        )

      :request when is_integer(sequence) ->
        IcsGenerator.generate_ics_update_attachment(ics_details, sequence, locale, filename)

      _other ->
        IcsGenerator.generate_ics_update_attachment(ics_details, 1, locale, filename)
    end
  end

  defp build_changes_table(changes) do
    rows =
      changes
      |> Enum.map(&change_to_row/1)
      |> Enum.filter(& &1)

    case rows do
      [] ->
        ""

      _rows ->
        tint = Styles.intent(@intent).tint
        accent = Styles.intent_accent(@intent)
        accent_ink = Styles.intent(@intent).accent_ink
        hairline = Styles.border_color(:subtle)

        body_rows =
          Enum.map_join(rows, "\n", fn {label, from_html, to_html} ->
            """
            <tr>
              <td style="padding: 10px 12px 10px 0; font-size: 11px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; vertical-align: top; border-bottom: 1px solid #{hairline}; width: 110px;">#{label}</td>
              <td style="padding: 10px 12px; color: #{Styles.ink_muted()}; font-size: 14px; vertical-align: top; border-bottom: 1px solid #{hairline}; text-decoration: line-through;">#{from_html}</td>
              <td style="padding: 10px 12px 10px 0; color: #{accent_ink}; font-size: 14px; font-weight: 600; vertical-align: top; border-bottom: 1px solid #{hairline};">#{to_html}</td>
            </tr>
            """
          end)

        """
        <mj-section
          background-color="#{tint}"
          border-radius="#{Styles.card_radius()}"
          padding="18px 22px"
          css-class="mobile-card"
        >
          <mj-column>
            <mj-text
              font-size="11px"
              font-weight="700"
              color="#{accent_ink}"
              letter-spacing="0.14em"
              text-transform="uppercase"
              padding="0 0 10px 0"
            >
              #{dgettext("emails", "What changed")}
            </mj-text>
            <mj-table border-left="3px solid #{accent}">
              <tr>
                <th style="padding: 6px 12px 6px 0; font-size: 10px; font-weight: 700; color: #{Styles.ink_whisper()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails", "Field")}</th>
                <th style="padding: 6px 12px; font-size: 10px; font-weight: 700; color: #{Styles.ink_whisper()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails", "Before")}</th>
                <th style="padding: 6px 12px 6px 0; font-size: 10px; font-weight: 700; color: #{Styles.ink_whisper()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails", "After")}</th>
              </tr>
              #{body_rows}
            </mj-table>
          </mj-column>
        </mj-section>
        """
    end
  end

  defp change_to_row({:title, from, to}),
    do: {dgettext("emails", "Title"), escape(from), escape(to)}

  defp change_to_row({:location, from, to}),
    do: {dgettext("emails", "Location"), escape(from), escape(to)}

  defp change_to_row({:description, _from, _to}),
    do:
      {dgettext("emails", "Description"), dgettext("emails", "(previous)"),
       dgettext("emails", "(updated)")}

  defp change_to_row({:time, from_start, to_start}),
    do:
      {dgettext("emails", "Time"), escape(Formatting.format_time_short(from_start)),
       escape(Formatting.format_time_short(to_start))}

  defp change_to_row(_other), do: nil

  defp escape(nil), do: dgettext("emails", "(none)")
  defp escape(val), do: val |> to_string() |> Sanitise.sanitize_for_email()

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
