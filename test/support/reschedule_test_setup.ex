defmodule Tymeslot.RescheduleTestSetup do
  @moduledoc """
  The organiser, schedule and confirmed meeting that every reschedule journey
  test starts from.

  Shared because the journey is covered by two modules, split where the booker
  commits: `RescheduleEntryTest` covers what the page offers them before that
  point, `RescheduleCompletionTest` what happens once they submit. Both need
  the same fixture, and a copy in each would drift.
  """

  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  @doc """
  Builds the fixture and returns it as an ExUnit context.

  Takes the test's tags so that Mox runs in global mode: the booking flow does
  its calendar work in processes the test does not own, and a private-mode
  expectation is invisible to them.
  """
  @spec reschedule_journey(map()) :: keyword()
  def reschedule_journey(tags) do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    timezone = "UTC"
    user = insert(:user, name: "Test Organizer")

    profile =
      insert(:profile,
        user: user,
        username: "reschedule-host",
        booking_theme: "1",
        timezone: timezone
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Quick Chat",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    _integration = insert(:calendar_integration, user: user, is_active: true)

    # The meeting being moved: far enough out that Policy's "already started"
    # and "already occurred" guards both pass. Truncated to the second because
    # `start_time` is `:utc_datetime`; without this the round-tripped value
    # never equals the one held here, and every "did it move?" assertion passes
    # whether or not anything moved.
    original_start =
      DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: user.name,
        meeting_type_id: meeting_type.id,
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com",
        attendee_timezone: timezone,
        start_time: original_start,
        end_time: DateTime.add(original_start, 30, :minute),
        duration: 30,
        status: "confirmed"
      )

    [
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    ]
  end
end
