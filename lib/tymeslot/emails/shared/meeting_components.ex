defmodule Tymeslot.Emails.Shared.MeetingComponents do
  @moduledoc """
  Public façade for the meeting-related email components — 2026 redesign.

  Each concern lives in a focused sibling module under
  `Tymeslot.Emails.Shared.Meeting.*`; this module re-exports them so callers
  have a single entry point for everything that renders a meeting inside an
  email.

  Sub-modules:

  - `Meeting.Hero` — the typographic hero block (`meeting_details_table/1,2`,
    `format_meeting_time/1,2`).
  - `Meeting.VideoSection` — the ticket-stub join CTA (`video_meeting_section/3`)
    and the reminder pill (`time_alert_badge/3`).
  - `Meeting.ActionsBar` — the reschedule / cancel link row
    (`meeting_actions_bar/2`).
  - `Meeting.CalendarLinks` — the add-to-calendar card
    (`calendar_links_section/1`).
  - `Meeting.Attendee` — the organiser-facing attendee table
    (`attendee_info_section/2`) and the attendee-message callout
    (`attendee_message_box/2`).
  - `Meeting.CustomAnswers` — the snapshotted custom-field answers table
    (`custom_answers_section/1`).
  """

  alias Tymeslot.Emails.Shared.Meeting.{
    ActionsBar,
    Attendee,
    CalendarLinks,
    CustomAnswers,
    Hero,
    VideoSection
  }

  defdelegate meeting_details_table(details), to: Hero
  defdelegate meeting_details_table(details, locale), to: Hero
  defdelegate format_meeting_time(details), to: Hero
  defdelegate format_meeting_time(details, locale), to: Hero

  defdelegate video_meeting_section(intent, meeting_url), to: VideoSection
  defdelegate video_meeting_section(intent, meeting_url, opts), to: VideoSection
  defdelegate time_alert_badge(intent, time_text), to: VideoSection
  defdelegate time_alert_badge(intent, time_text, opts), to: VideoSection

  defdelegate meeting_actions_bar(intent, actions), to: ActionsBar

  defdelegate calendar_links_section(meeting_details), to: CalendarLinks

  defdelegate attendee_info_section(intent, attendee), to: Attendee
  defdelegate attendee_message_box(intent, message), to: Attendee

  defdelegate custom_answers_section(appointment_details), to: CustomAnswers
end
