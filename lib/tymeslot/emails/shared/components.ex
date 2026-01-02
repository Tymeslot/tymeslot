defmodule Tymeslot.Emails.Shared.Components do
  @moduledoc """
  Reusable MJML components for email templates.

  This module serves as a compatibility layer that delegates to specific component modules.
  For new development, consider using the specific modules directly:

  - `Tymeslot.Emails.Shared.MeetingComponents` - Meeting details, video sections, time formatting
  - `Tymeslot.Emails.Shared.UiComponents` - Buttons, alerts, dividers, grids
  - `Tymeslot.Emails.Shared.CalendarComponents` - Calendar links, attendee info
  - `Tymeslot.Emails.Shared.ContentComponents` - Message boxes, content sections
  """

  # Import all the specialized component modules
  alias Tymeslot.Emails.Shared.{
    CalendarComponents,
    ContentComponents,
    MeetingComponents,
    UiComponents
  }

  # Meeting Components delegation
  defdelegate meeting_details_table(details), to: MeetingComponents
  defdelegate video_meeting_section(meeting_url, opts \\ []), to: MeetingComponents
  defdelegate time_alert_badge(time_text, opts \\ []), to: MeetingComponents
  defdelegate meeting_actions_bar(actions), to: MeetingComponents
  defdelegate format_meeting_time(details), to: MeetingComponents

  # UI Components delegation
  defdelegate action_button(text, url, opts \\ []), to: UiComponents
  defdelegate action_button_group(buttons), to: UiComponents
  defdelegate alert_box(type, message, opts \\ []), to: UiComponents
  defdelegate divider(opts \\ []), to: UiComponents
  defdelegate title_section(title, opts \\ []), to: UiComponents
  defdelegate quick_info_grid(items), to: UiComponents
  defdelegate preparation_checklist(items, opts \\ []), to: UiComponents
  defdelegate footer_actions(actions), to: UiComponents

  # Calendar Components delegation
  defdelegate calendar_links_section(meeting_details), to: CalendarComponents
  defdelegate attendee_info_section(attendee), to: CalendarComponents

  # Content Components delegation
  defdelegate attendee_message_box(message), to: ContentComponents
end
