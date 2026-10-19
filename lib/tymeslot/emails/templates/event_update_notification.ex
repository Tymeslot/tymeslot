defmodule Tymeslot.Emails.Templates.EventUpdateNotification do
  @moduledoc """
  Email template for notifying attendees of calendar event updates from the dashboard.

  Sent when an organiser edits an existing event (title, time, location, description).
  Includes a highlighted change summary and an updated ICS attachment with SEQUENCE=1.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.Stack

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

    - `attendee_email`: recipient email address (string)
    - `details`: map with event details:
      - `:event_title`: current event title
      - `:event_uid`: stable UID used across invitations
      - `:all_day`: whether the event is all-day (optional, default false)
      - `:start_time`: updated start time (`DateTime`; nil for an all-day event)
      - `:end_time`: updated end time (`DateTime`; nil for an all-day event)
      - `:date`: event date (`Date`), the first day of an all-day event
      - `:duration`: duration in minutes (nil for an all-day event)
      - `:start_date`, `:end_date`: an all-day event's first day and
        exclusive end date, for the ICS attachment
      - `:last_date`: an all-day event's inclusive last day, for display
      - `:location`: location string or nil
      - `:description`: description string or nil
      - `:organizer_name`: organiser display name
      - `:organizer_email`: organiser email address
      - `:changes`: list of `{field, old_value, new_value}` tuples
      - `:first_notification`: true when no previous state was ever
        recorded; the changes then carry nil old values and render as the
        event's current details rather than a before/after diff (optional)
      - `:series`: `:all` or `:following` for the update of every
        occurrence of a repeating event, or of this and every following
        one, whose details are then those of the occurrence edited
        (optional)
      - `:attendee_locale`: optional locale string (default: the booking pages' fallback locale)
  """
  @spec render(String.t(), map()) :: Swoosh.Email.t()
  def render(attendee_email, details) do
    locale = RecipientLocale.attendee_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details =
        details
        |> Map.take([:all_day, :last_date])
        |> Map.merge(%{
          date: details.date,
          start_time: details.start_time,
          duration: details.duration,
          location: details.location,
          location_type: if(details.location, do: :in_person),
          meeting_type: details.event_title
        })

      changes_table =
        if first_notification?(details),
          do: build_details_table(details.changes, locale),
          else: build_changes_table(details.changes, locale)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{changes_table}
      """

      details_for_organizer = Map.put_new(details, :organizer_title, nil)

      organizer_details =
        TemplateHelper.build_organizer_details(details_for_organizer,
          intent: @intent,
          eyebrow: dgettext("emails_booking_changes", "Updated"),
          stage_title: dgettext("emails_booking_changes", "Event updated"),
          stage_subtitle: updated_line(details)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(details.date, locale)

      ics_details = %{
        all_day: Map.get(details, :all_day, false),
        start_date: Map.get(details, :start_date),
        end_date: Map.get(details, :end_date),
        title: details.event_title,
        start_time: details.start_time,
        end_time: details.end_time,
        uid: details.event_uid,
        location: details.location,
        description: details.description,
        organizer_name: details.organizer_name,
        organizer_email: details.organizer_email,
        organizer_user_id: Map.get(details, :organizer_user_id),
        attendee_email: attendee_email
      }

      MjmlEmail.base_email()
      |> to(attendee_email)
      |> MjmlEmail.put_reply_to(details.organizer_name, details.organizer_email)
      |> subject(
        dgettext("emails_booking_changes", "Updated: %{title} - %{date}",
          title: details.event_title,
          date: date_short
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(details, meeting_details, locale))
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

  defp build_changes_table(changes, locale) do
    rows =
      changes
      |> Enum.map(&change_to_row(&1, locale))
      |> Enum.filter(& &1)

    case rows do
      [] ->
        ""

      _rows ->
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

        change_section(dgettext("emails_booking_changes", "What changed"), """
        <tr>
          <th style="padding: 6px 12px 6px 0; font-size: 10px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails_booking_changes", "Field")}</th>
          <th style="padding: 6px 12px; font-size: 10px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails_booking_changes", "Before")}</th>
          <th style="padding: 6px 12px 6px 0; font-size: 10px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; text-align: left;">#{dgettext("emails_booking_changes", "After")}</th>
        </tr>
        #{body_rows}
        """)
    end
  end

  # The tinted card both change tables sit in.
  defp change_section(heading, table_rows) do
    tint = Styles.intent(@intent).tint
    accent = Styles.intent_accent(@intent)
    accent_ink = Styles.intent(@intent).accent_ink

    Stack.spaced("""
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
          #{heading}
        </mj-text>
        <mj-table border-left="3px solid #{accent}">
          #{table_rows}
        </mj-table>
      </mj-column>
    </mj-section>
    """)
  end

  defp first_notification?(details), do: Map.get(details, :first_notification) == true

  # The details shown are those of the occurrence the organiser edited, so an
  # update of more of the series says how much more it changed.
  defp updated_line(%{series: :all} = details) do
    dgettext(
      "emails_booking_changes",
      "%{name} has updated every occurrence of a repeating event you're attending.",
      name: details.organizer_name
    )
  end

  defp updated_line(%{series: :following} = details) do
    dgettext(
      "emails_booking_changes",
      "%{name} has updated this and every following occurrence of a repeating event you're attending.",
      name: details.organizer_name
    )
  end

  defp updated_line(details) do
    dgettext("emails_booking_changes", "%{name} has updated an event you're attending.",
      name: details.organizer_name
    )
  end

  # The first-notification variant of the change table: the event's current
  # details, one row per populated field, with no "before" column, because
  # nothing was ever recorded to put in it.
  defp build_details_table(changes, locale) do
    rows = Enum.map_join(changes, "\n", &detail_row(&1, locale))
    change_section(dgettext("emails_booking_changes", "Current details"), rows)
  end

  defp detail_row(change, locale) do
    {label, value_html} = detail_cells(change, locale)
    hairline = Styles.border_color(:subtle)

    """
    <tr>
      <td style="padding: 10px 12px 10px 0; font-size: 11px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; vertical-align: top; border-bottom: 1px solid #{hairline}; width: 110px;">#{label}</td>
      <td style="padding: 10px 12px; color: #{Styles.intent(@intent).accent_ink}; font-size: 14px; font-weight: 600; vertical-align: top; border-bottom: 1px solid #{hairline};">#{value_html}</td>
    </tr>
    """
  end

  defp detail_cells({:title, _from, to}, _locale),
    do: {dgettext("emails_booking_changes", "Title"), escape(to)}

  defp detail_cells({:location, _from, to}, _locale),
    do: {dgettext("emails_booking_changes", "Location"), escape(to)}

  defp detail_cells({:description, _from, to}, _locale),
    do: {dgettext("emails_booking_changes", "Description"), escape(Formatting.plain_excerpt(to))}

  defp detail_cells({:time, _from, to}, locale),
    do:
      {dgettext("emails_booking_changes", "Time"),
       escape(Formatting.format_time_short(to, locale))}

  defp change_to_row({:title, from, to}, _locale),
    do: {dgettext("emails_booking_changes", "Title"), escape(from), escape(to)}

  defp change_to_row({:location, from, to}, _locale),
    do: {dgettext("emails_booking_changes", "Location"), escape(from), escape(to)}

  defp change_to_row({:description, _from, _to}, _locale),
    do:
      {dgettext("emails_booking_changes", "Description"),
       dgettext("emails_booking_changes", "(previous)"),
       dgettext("emails_booking_changes", "(updated)")}

  defp change_to_row({:time, from_start, to_start}, locale),
    do:
      {dgettext("emails_booking_changes", "Time"),
       escape(Formatting.format_time_short(from_start, locale)),
       escape(Formatting.format_time_short(to_start, locale))}

  defp change_to_row(_other, _locale), do: nil

  defp escape(nil), do: dgettext("emails_booking_changes", "(none)")
  defp escape(val), do: val |> to_string() |> Sanitise.sanitize_for_email()

  defp build_text_body(details, meeting_details, locale) do
    {changes_heading, changes_text} =
      if first_notification?(details),
        do:
          {dgettext("emails_booking_changes", "Current Details"),
           TextBodyHelper.format_event_details(details.changes, locale)},
        else:
          {dgettext("emails_booking_changes", "What Changed"),
           TextBodyHelper.format_event_changes(details.changes, locale)}

    """
    #{dgettext("emails_booking_changes", "Event Updated")}

    #{updated_line(details)}

    #{dgettext("emails_booking_changes", "MEETING DETAILS:")}
    #{TextBodyHelper.format_meeting_details(meeting_details, locale)}

    #{changes_heading}
    #{changes_text}

    #{details.organizer_name}
    """
  end
end
