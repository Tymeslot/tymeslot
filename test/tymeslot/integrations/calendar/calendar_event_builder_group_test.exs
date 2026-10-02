defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderGroupTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder

  @group_meeting %{
    attendee_name: nil,
    attendee_email: nil,
    description: nil,
    attendee_message: nil,
    custom_fields_snapshot: nil,
    custom_field_answers: nil,
    attachments_snapshot: nil,
    meeting_url: nil
  }

  # The builder is pure: it renders whichever attendees the caller passes in
  # via the `:attendees` option. Filtering to live (non-cancelled)
  # participants is the caller's responsibility (`Tymeslot.Meetings.recipients/1`,
  # covered by `Tymeslot.Meetings.RecipientTest`), not the builder's.
  test "group meeting description lists the given attendees" do
    attendees = [%{name: "Alice", email: "alice@example.com"}]

    description =
      CalendarEventBuilder.build_event_description(@group_meeting, attendees: attendees)

    assert description =~ "Attendees (1):"
    assert description =~ "Alice <alice@example.com>"
  end

  test "group meeting with no attendees passed in renders no attendee line" do
    description = CalendarEventBuilder.build_event_description(@group_meeting)

    refute description =~ "Attendees ("
  end

  test "solo meetings keep the existing single-attendee line when no attendees are passed" do
    meeting = %{@group_meeting | attendee_name: "Solo", attendee_email: "solo@example.com"}

    description = CalendarEventBuilder.build_event_description(meeting)

    assert description =~ "Attendee: Solo <solo@example.com>"
    refute description =~ "Attendees ("
  end
end
