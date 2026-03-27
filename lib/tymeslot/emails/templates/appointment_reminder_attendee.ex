defmodule Tymeslot.Emails.Templates.AppointmentReminderAttendee do
  @moduledoc """
  Email module for sending appointment reminders to the attendee.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    Styles,
    TemplateHelper,
    TextBodyHelper
  }

  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @spec reminder_email(String.t(), map()) :: Swoosh.Email.t()
  def reminder_email(attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      time_str =
        LocaleFormat.format_time(
          DateTime.to_time(appointment_details.start_time_attendee_tz),
          locale
        )

      mjml_content = """
      #{Components.time_alert_badge(appointment_details.time_until, icon: "⏰", color: :blue)}

      #{Components.title_section(dgettext("emails", "Our meeting is coming up!"),
      emoji: "📅",
      align: "center")}

      <mj-section padding="0 0 12px 0">
        <mj-column>
          <mj-text
            font-size="18px"
            font-weight="600"
            color="#{Styles.text_color(:primary)}"
            align="center"
            padding="0 0 4px 0"
            line-height="1.4"
            css-class="mobile-text"
          >
            #{SharedHelpers.format_date_short(appointment_details.date, locale)}
          </mj-text>
          <mj-text
            font-size="16px"
            color="#{Styles.text_color(:secondary)}"
            align="center"
            padding="0"
            css-class="mobile-text"
          >
            #{time_str} #{appointment_details.attendee_timezone}
          </mj-text>
        </mj-column>
      </mj-section>

      #{Components.quick_info_grid([%{label: dgettext("emails", "Duration"), value: "#{appointment_details.duration} #{dgettext("emails", "min")}"}, %{label: dgettext("emails", "Location"), value: SharedHelpers.format_location(appointment_details)}])}

      #{if Map.get(appointment_details, :meeting_url) do
        Components.video_meeting_section(appointment_details.meeting_url,
        style: :reminder,
        title: dgettext("emails", "Join When Ready"),
        button_text: dgettext("emails", "Join Meeting"))
      end}

      <mj-section padding="8px 0">
        <mj-column>
          <mj-text
            font-size="13px"
            color="#{Styles.text_color(:secondary)}"
            align="center"
            padding="0 0 8px 0"
            css-class="mobile-text"
          >
            #{dgettext("emails", "Need to change plans?")}
          </mj-text>
        </mj-column>
      </mj-section>

      #{Components.meeting_actions_bar([%{text: dgettext("emails", "Reschedule"), url: appointment_details.reschedule_url, style: :secondary}, %{text: dgettext("emails", "Cancel"), url: appointment_details.cancel_url, style: :danger}])}

      <mj-section padding="12px 0 0 0">
        <mj-column>
          <mj-text
            align="center"
            font-size="15px"
            color="#{Styles.text_color(:dark)}"
            line-height="1.5"
            css-class="mobile-text"
          >
            #{dgettext("emails", "I'm looking forward to our conversation!")}
          </mj-text>
          <mj-text
            align="center"
            font-size="14px"
            color="#{Styles.text_color(:secondary)}"
            padding-top="8px"
            css-class="mobile-text"
          >
            #{dgettext("emails", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails", "soon"))}
          </mj-text>
        </mj-column>
      </mj-section>
      """

      organizer_details = TemplateHelper.build_organizer_details(appointment_details)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        dgettext("emails", "Reminder: Our meeting is %{time_until}",
          time_until: appointment_details.time_until
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(appointment_details, locale))
    end)
  end

  defp build_text_body(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)
    video_section = TextBodyHelper.format_video_section(appointment_details.meeting_url, locale)
    action_links = TextBodyHelper.format_action_links(appointment_details, locale)

    """
    #{dgettext("emails", "REMINDER: Our meeting in %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "I'm looking forward to our conversation!")}

    #{dgettext("emails", "DETAILS:")}
    #{meeting_details}#{video_section}
    #{dgettext("emails", "Need to change plans?")}#{action_links}

    #{dgettext("emails", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails", "soon"))}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end
end
