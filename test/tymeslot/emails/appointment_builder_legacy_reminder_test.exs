defmodule Tymeslot.Emails.AppointmentBuilderLegacyReminderTest do
  @moduledoc """
  The reminder of a booking made before reminders were stored as a value and
  unit: it carries an English label instead, which is read as an interval and
  given in each recipient's language like any other reminder.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentReminder

  import Tymeslot.MeetingTestHelpers

  describe "from_meeting/1 with a legacy reminder label" do
    test "localises a legacy reminder label for both recipients" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminders: [],
          reminder_time: "30 minutes",
          attendee_locale: "de"
        })

      details =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          AppointmentBuilder.from_meeting(meeting)
        end)

      assert details.reminder_raw == %{value: 30, unit: "minutes"}
      assert details.time_until == "30 Minuten"

      organizer_copy =
        AppointmentReminder.render(
          :organizer,
          "organizer@example.com",
          Map.put(details, :organizer_locale, "en")
        )

      assert organizer_copy.subject =~ "in 30 minutes"
      refute organizer_copy.subject =~ "Minuten"
    end

    test "keeps a legacy reminder label that is not an interval as it is" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminders: [],
          reminder_time: "the evening before"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.reminder_time == "the evening before"
      refute Map.has_key?(result, :reminder_raw)
    end
  end
end
