defmodule Tymeslot.Emails.Templates.AppointmentCancellation do
  @moduledoc """
  Email module for sending appointment cancellation notifications.
  """

  import Swoosh.Email

  alias Tymeslot.Locales

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @spec cancellation_email_attendee(String.t(), map()) :: Swoosh.Email.t()
  def cancellation_email_attendee(attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      mjml_content = """
      #{Components.alert_box("error",
      dgettext("emails", "Hi %{name}, I wanted to let you know that our appointment has been cancelled.", name: appointment_details.attendee_name),
      icon: "✕",
      title: dgettext("emails", "Meeting Cancelled"))}

      #{Components.section_title(dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name), padding: "24px 0 16px 0")}

      #{Components.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type}, locale)}

      #{Components.centered_text(dgettext("emails", "Would you like to schedule a new appointment?"), padding: "24px 0 8px 0")}
      #{Components.action_button(dgettext("emails", "Schedule New Appointment"), SharedHelpers.get_app_url(), color: "primary", full_width: true)}

      #{Components.system_footer_note(dgettext("emails", "This time slot is now available for booking again."))}
      #{Components.system_footer_note(dgettext("emails", "If you have any questions, please don't hesitate to reach out."))}
      """

      organizer_details = TemplateHelper.build_organizer_details(appointment_details)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = SharedHelpers.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        dgettext("emails", "Meeting Cancelled - %{date} with %{name}",
          date: date_short,
          name: appointment_details.organizer_name
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_attendee(appointment_details, locale))
    end)
  end

  @spec cancellation_email_organizer(String.t(), map()) :: Swoosh.Email.t()
  def cancellation_email_organizer(organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(), fn ->
      mjml_content = """
      #{Components.alert_box("error",
      dgettext("emails", "The appointment with %{name} has been cancelled.", name: appointment_details.attendee_name),
      icon: "✕",
      title: dgettext("emails", "Meeting Cancelled"))}

      #{Components.section_title(dgettext("emails", "Meeting with %{name}", name: appointment_details.attendee_name), padding: "24px 0 16px 0")}

      #{Components.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type}, organizer_locale())}

      #{Components.system_footer_note(dgettext("emails", "Your calendar has been updated to reflect this cancellation."))}
      #{Components.system_footer_note(dgettext("emails", "The attendee has been notified of the cancellation."))}
      """

      organizer_details = TemplateHelper.build_organizer_details(appointment_details)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        dgettext("emails", "Meeting Cancelled - %{date} with %{name}",
          date: SharedHelpers.format_date_short(appointment_details.date, organizer_locale()),
          name: appointment_details.attendee_name
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_organizer(appointment_details))
    end)
  end

  defp text_body_attendee(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    """
    #{dgettext("emails", "Meeting Cancelled")}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "We're writing to confirm that your appointment has been cancelled.")}

    #{dgettext("emails", "CANCELLED APPOINTMENT DETAILS:")}
    #{dgettext("emails", "Meeting with:")} #{appointment_details.organizer_name}
    #{meeting_details}

    #{dgettext("emails", "This time slot is now available for booking again.")}

    #{dgettext("emails", "Would you like to schedule a new appointment?")}
    #{dgettext("emails", "Visit:")} #{SharedHelpers.get_app_url()}

    #{dgettext("emails", "If you have any questions, please don't hesitate to reach out.")}
    """
  end

  defp organizer_locale, do: Locales.default_locale()

  defp text_body_organizer(appointment_details) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, organizer_locale())
    attendee_info = TextBodyHelper.format_attendee_info(appointment_details, organizer_locale())

    """
    #{dgettext("emails", "Meeting Cancelled")}

    #{dgettext("emails", "The appointment with %{name} has been cancelled.", name: appointment_details.attendee_name)}

    #{dgettext("emails", "CANCELLED APPOINTMENT DETAILS:")}
    #{meeting_details}#{attendee_info}

    #{dgettext("emails", "Your calendar has been updated to reflect this cancellation.")}
    #{dgettext("emails", "The attendee has been notified of the cancellation.")}
    """
  end
end
