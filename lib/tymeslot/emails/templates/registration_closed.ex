defmodule Tymeslot.Emails.Templates.RegistrationClosed do
  @moduledoc """
  The organiser's email when registration for a planned session
  (`Tymeslot.Meetings.PlannedSessions`) has closed: who signed up, so the
  host can prepare for the session (print a list, order the catering, send
  material) without looking each booking up in the dashboard.

  The payload is `Tymeslot.Emails.AppointmentBuilder.for_organizer_of_group/3`
  for the session, and the roster, one entry per live participant in
  sign-up order: their details, the guests they brought and their answers
  to the type's questions. With people signed up, the roster is also
  attached as a CSV file, one row per participant, for a spreadsheet or a
  printout. When nobody signed up, the email says so, since the host may
  want to call the session off.

  Like every organiser email, it carries no calendar file (see
  `Tymeslot.Emails.Templates.SeatUpdateForOrganizer`).
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @type entry :: %{
          name: String.t(),
          email: String.t(),
          phone: String.t() | nil,
          company: String.t() | nil,
          message: String.t() | nil,
          guests: [%{name: String.t() | nil, email: String.t()}],
          answers: [{String.t(), String.t()}]
        }

  @spec render(String.t(), Tymeslot.Emails.EmailService.appointment_details(), [entry()]) ::
          Swoosh.Email.t()
  def render(organizer_email, details, roster) do
    details = Formatting.without_location_note(details)
    locale = RecipientLocale.organizer_locale(details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      copy = copy(details, roster, locale)

      mjml_content = """
      #{Text.centered_text(copy.lead, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(TemplateHelper.organizer_meeting_details(details), locale)}

      #{if line = seats_line(details, roster), do: Text.centered_text(line, font_size: "14px", padding: "8px 0 8px 0")}

      #{roster_html(roster)}

      #{MeetingComponents.meeting_actions_bar(:confirmed, [%{text: dgettext("emails_booking", "Open in dashboard"), url: details.dashboard_url, style: :primary}])}
      """

      stage =
        TemplateHelper.build_organizer_details(details,
          intent: :confirmed,
          eyebrow: dgettext("emails_booking", "Registration closed"),
          stage_title: copy.title,
          stage_subtitle: details.meeting_type || ""
        )

      MjmlEmail.base_email()
      |> to({details.organizer_name, organizer_email})
      |> subject(Sanitise.sanitize_for_header(copy.subject))
      |> html_body(TemplateHelper.compile_template(mjml_content, stage))
      |> text_body(text_body(details, roster, copy, locale))
      |> maybe_attach_csv(roster, details, locale)
    end)
  end

  @doc """
  The roster as CSV: a header row, then one row per participant. Starts
  with a byte order mark so spreadsheet programs read it as UTF-8, and
  neutralises cells a spreadsheet would run as a formula.
  """
  @spec csv([entry()]) :: String.t()
  def csv(roster) do
    questions = roster |> Enum.flat_map(& &1.answers) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    header =
      [
        dgettext("emails_booking", "Name"),
        dgettext("emails_booking", "Email"),
        dgettext("emails_booking", "Phone"),
        dgettext("emails_booking", "Company"),
        dgettext("emails_booking", "Guests"),
        dgettext("emails_booking", "Message")
      ] ++ questions

    rows =
      Enum.map(roster, fn entry ->
        answers = Map.new(entry.answers)

        [
          entry.name,
          entry.email,
          entry.phone,
          entry.company,
          Enum.map_join(entry.guests, "; ", &guest_label/1),
          entry.message
        ] ++ Enum.map(questions, &Map.get(answers, &1))
      end)

    "﻿" <> Enum.map_join([header | rows], "", &csv_row/1)
  end

  defp copy(details, roster, locale) do
    event = details.meeting_type || ""
    date = Formatting.format_date_short(details.date, locale)

    lead =
      case length(roster) do
        0 ->
          dgettext(
            "emails_booking",
            "Nobody signed up for %{event}. If it is not going ahead, you can cancel it in your dashboard.",
            event: event
          )

        count ->
          dngettext(
            "emails_booking",
            "%{count} person signed up for %{event}. Here is who is coming.",
            "%{count} people signed up for %{event}. Here is who is coming.",
            count,
            event: event
          )
      end

    %{
      title: dgettext("emails_booking", "Registration has closed"),
      lead: lead,
      subject:
        dgettext("emails_booking", "Registration closed: %{event} - %{date}",
          event: event,
          date: date
        )
    }
  end

  # How full the session is, guests included: each guest takes a seat.
  defp seats_line(_details, []), do: nil

  defp seats_line(details, roster) do
    taken = Enum.reduce(roster, 0, &(&2 + 1 + length(&1.guests)))

    dngettext(
      "emails_booking",
      "%{taken} of %{count} spot taken",
      "%{taken} of %{count} spots taken",
      details.capacity,
      taken: taken,
      count: details.capacity
    )
  end

  defp roster_html([]), do: ""

  defp roster_html(roster) do
    items = Enum.map_join(roster, "<br/><br/>\n", &entry_html/1)

    """
    #{Text.section_title(dgettext("emails_booking", "Participants"))}
    <mj-section padding="0 0 8px 0">
      <mj-column>
        <mj-text font-size="15px" line-height="1.6" padding="0 24px">
          #{items}
        </mj-text>
      </mj-column>
    </mj-section>
    #{Text.system_footer_note(dgettext("emails_booking", "The list is also attached as a CSV file for a spreadsheet."))}
    """
  end

  defp entry_html(entry) do
    lines =
      [
        "<strong>#{Sanitise.sanitize_for_email(entry.name)}</strong>",
        Sanitise.sanitize_for_email(entry.email),
        entry.phone && Sanitise.sanitize_for_email(entry.phone),
        entry.company && Sanitise.sanitize_for_email(entry.company),
        guests_line(entry.guests) && Sanitise.sanitize_for_email(guests_line(entry.guests))
      ] ++
        Enum.map(entry.answers, fn {label, value} ->
          Sanitise.sanitize_for_email("#{label}: #{value}")
        end) ++
        [
          entry.message &&
            Sanitise.sanitize_for_email(
              dgettext("emails_booking", "Message: %{message}", message: entry.message)
            )
        ]

    lines |> Enum.reject(&blank?/1) |> Enum.join("<br/>")
  end

  defp guests_line([]), do: nil

  defp guests_line(guests),
    do:
      dgettext("emails_booking", "Guests: %{guests}",
        guests: Enum.map_join(guests, ", ", &guest_label/1)
      )

  defp guest_label(%{name: name, email: email}) when is_binary(name) and name != "",
    do: "#{name} <#{email}>"

  defp guest_label(%{email: email}), do: email

  defp text_body(details, roster, copy, locale) do
    view = TemplateHelper.as_organizer_view(details)

    entries =
      Enum.map_join(roster, "\n", fn entry ->
        entry
        |> entry_text()
        |> Enum.map_join("\n", &("  " <> &1))
        |> String.replace_prefix("  ", "- ")
      end)

    """
    #{copy.title}

    #{copy.lead}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{TextBodyHelper.format_meeting_details(view, locale)}

    #{seats_line(details, roster)}

    #{entries}

    #{dgettext("emails_booking", "Open in dashboard")}: #{details.dashboard_url}
    """
  end

  defp entry_text(entry) do
    lines =
      [entry.name, entry.email, entry.phone, entry.company, guests_line(entry.guests)] ++
        Enum.map(entry.answers, fn {label, value} -> "#{label}: #{value}" end) ++
        [
          entry.message &&
            dgettext("emails_booking", "Message: %{message}", message: entry.message)
        ]

    Enum.reject(lines, &blank?/1)
  end

  defp maybe_attach_csv(email, [], _details, _locale), do: email

  defp maybe_attach_csv(email, roster, details, _locale) do
    attachment(email, %Swoosh.Attachment{
      filename: "participants-#{Date.to_iso8601(details.date)}.csv",
      content_type: "text/csv",
      data: csv(roster)
    })
  end

  defp csv_row(cells), do: Enum.map_join(cells, ",", &csv_cell/1) <> "\r\n"

  defp csv_cell(nil), do: csv_cell("")

  defp csv_cell(value) do
    value = to_string(value)

    # A cell starting like a formula is run by spreadsheet programs; a
    # leading apostrophe makes it plain text.
    value =
      if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]),
        do: "'" <> value,
        else: value

    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""
end
