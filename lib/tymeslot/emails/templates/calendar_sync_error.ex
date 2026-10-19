defmodule Tymeslot.Emails.Templates.CalendarSyncError do
  @moduledoc """
  MJML template for calendar sync error notification sent to the calendar owner.

  Addressed to the meeting's organiser (the instance's sender address when
  the meeting has none) and rendered in their locale, resolved from
  `organizer_user_id`.
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Styles,
    TemplateHelper,
    Text
  }

  alias Tymeslot.Utils.DateTimeUtils

  alias Tymeslot.Emails.HostClock

  use Gettext, backend: TymeslotWeb.Gettext

  # A sync failure the user needs to act on.
  @intent :alert

  @type meeting_map :: %{
          required(:start_time) => DateTime.t(),
          required(:organizer_email) => String.t() | nil,
          required(:organizer_name) => String.t() | nil,
          required(:duration) => integer(),
          required(:location) => String.t() | nil,
          optional(:organizer_user_id) => term(),
          optional(atom()) => term()
        }

  @doc """
  The email to the meeting's organiser, in their locale, computing their
  local start time only once for both parts.
  """
  @spec render(meeting_map(), any()) :: Email.t()
  def render(meeting, error_reason) do
    RecipientLocale.with_user_id_locale(Map.get(meeting, :organizer_user_id), fn ->
      error_details = TemplateHelper.format_error_reason(error_reason)
      locale = Gettext.get_locale(TymeslotWeb.Gettext)
      clock = HostClock.for_meeting(meeting, locale)
      owner_start_time = DateTimeUtils.convert_to_timezone(meeting.start_time, clock.timezone)

      MjmlEmail.base_email()
      |> Email.to(recipient(meeting))
      |> Email.subject(
        dgettext("emails_integrations", "⚠️ Calendar Sync Error - Manual Action Required")
      )
      |> Email.html_body(
        do_render_html(error_details, {owner_start_time, clock}, meeting, locale)
      )
      |> Email.text_body(
        do_render_text(error_details, {owner_start_time, clock}, meeting, locale)
      )
    end)
  end

  @doc """
  The address the email goes to: the meeting's organiser, or the instance's
  sender address when the meeting has none.
  """
  @spec recipient_email(meeting_map()) :: String.t()
  def recipient_email(meeting),
    do: meeting.organizer_email || Application.get_env(:tymeslot, :email)[:from_email]

  defp recipient(meeting) do
    {meeting.organizer_name || dgettext("emails_integrations", "Calendar Owner"),
     recipient_email(meeting)}
  end

  defp do_render_html(error_details, {owner_start_time, clock}, meeting, locale) do
    mjml_content = """
    #{Callouts.alert_box(:cancelled,
    dgettext("emails_integrations", "I was unable to add this meeting to your calendar. The appointment has been successfully confirmed in Tymeslot and both you and the attendee have received confirmation emails. However, you'll need to manually add it to your calendar."),
    title: dgettext("emails_integrations", "Calendar Sync Error"))}

    #{Text.title_section(dgettext("emails_integrations", "Meeting Details"))}
    #{MeetingComponents.meeting_details_table(%{date: owner_start_time, start_time: owner_start_time, duration: meeting.duration, location: meeting.location, time_format: clock.time_format}, locale)}

    #{Text.divider()}

    #{Text.title_section(dgettext("emails_integrations", "Error Details"))}

    #{Callouts.alert_box(:cancelled, error_details, title: dgettext("emails_integrations", "Error"))}

    #{Text.title_section(dgettext("emails_integrations", "Action Required"))}

    <mj-text color="#{Styles.ink_soft()}">
      #{dgettext("emails_integrations", "Please manually add this meeting to your calendar to ensure you don't miss it. Both you and the attendee have already received your confirmation emails - this is purely a technical calendar sync issue that doesn't affect the booking itself.")}
    </mj-text>

    #{Callouts.alert_box(:alert, dgettext("emails_integrations", "Common causes:"), items: common_causes())}

    #{Text.system_footer_note(dgettext("emails_integrations", "This is an automated system notification. Please check your calendar sync settings if this issue persists."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_integrations", "Calendar Sync Error"),
      dgettext("emails_integrations", "A meeting could not be added to your calendar."),
      intent: @intent,
      eyebrow: dgettext("emails_integrations", "Action required"),
      stage_title: dgettext("emails_integrations", "Calendar didn't sync"),
      stage_subtitle:
        dgettext(
          "emails_integrations",
          "The booking is safe - but please add it to your calendar manually."
        )
    )
  end

  defp do_render_text(error_details, {owner_start_time, clock}, meeting, locale) do
    """
    #{dgettext("emails_integrations", "Calendar Sync Error - Manual Action Required")}

    #{dgettext("emails_integrations", "I was unable to add this meeting to your calendar. The appointment has been successfully confirmed in Tymeslot and both you and the attendee have received confirmation emails. However, you'll need to manually add it to your calendar.")}

    #{dgettext("emails_integrations", "MEETING DETAILS:")}
    #{dgettext("emails_integrations", "Date:")} #{Formatting.format_date(owner_start_time, locale)}
    #{dgettext("emails_integrations", "Time:")} #{Formatting.format_time(owner_start_time, locale, clock.time_format)}
    #{dgettext("emails_integrations", "Duration:")} #{Formatting.format_duration(meeting.duration, locale)}
    #{dgettext("emails_integrations", "Location:")} #{meeting.location || dgettext("emails_integrations", "Not specified")}

    #{dgettext("emails_integrations", "ERROR DETAILS:")}
    #{error_details}

    #{dgettext("emails_integrations", "ACTION REQUIRED:")}
    #{dgettext("emails_integrations", "Please manually add this meeting to your calendar to ensure you don't miss it. Both you and the attendee have already received your confirmation emails - this is purely a technical calendar sync issue that doesn't affect the booking itself.")}

    #{common_causes_text()}

    #{dgettext("emails_integrations", "This is an automated system notification. Please check your calendar sync settings if this issue persists.")}
    """
  end

  # The four causes are one list translated once, then laid out by whichever body
  # needs them. Keeping them as separate msgids from the surrounding prose means
  # a translator never has to reproduce list markup by hand.
  defp common_causes do
    [
      dgettext("emails_integrations", "CalDAV server temporarily unavailable"),
      dgettext("emails_integrations", "Network connectivity issues"),
      dgettext("emails_integrations", "Calendar permissions or authentication problems"),
      dgettext("emails_integrations", "Maximum retries exceeded")
    ]
  end

  defp common_causes_text do
    causes = Enum.map_join(common_causes(), "\n- ", & &1)
    "#{dgettext("emails_integrations", "Common causes:")}\n- #{causes}"
  end
end
