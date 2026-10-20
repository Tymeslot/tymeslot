defmodule Tymeslot.Migrations.LowerUnprovenTymeslotOwnershipOnCachedEventsTest do
  @moduledoc """
  Value-correctness regression for
  `20261020104547_lower_unproven_tymeslot_ownership_on_cached_events`, which
  clears `created_by_tymeslot` on cached events the CalDAV offline queue
  wrongly claimed.

  The decisive properties: a flagged row with neither a Tymeslot UID nor a
  meeting is lowered, and nothing that can prove its ownership is: a
  grid-created event (or one instance of its series), a booking matched by
  UID or by provider event id in either of the meeting's two fields, even
  through another integration, and every
  Google or Outlook row, whose flag the provider's marker decides.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_020_104_547

  setup do
    user = insert(:user)
    caldav = insert(:calendar_integration, user: user, provider: "caldav")
    {:ok, user: user, caldav: caldav}
  end

  defp cached!(integration, attrs) do
    insert(
      :provider_calendar_event,
      [calendar_integration: integration, created_by_tymeslot: true] ++ attrs
    )
  end

  defp flag(event), do: Repo.get!(ProviderCalendarEventSchema, event.id).created_by_tymeslot

  test "lowers a CalDAV event the queue claimed that nothing proves is Tymeslot's",
       %{caldav: caldav} do
    foreign = cached!(caldav, uid: "f00d@example.org", provider_event_id: "/cal/f00d.ics")

    MigrationRunner.replay!(@version)

    refute flag(foreign)
  end

  test "keeps a grid-created event and an instance of a grid-created series",
       %{caldav: caldav} do
    created = cached!(caldav, uid: "0a1b2c@tymeslot.com")
    instance = cached!(caldav, uid: "0a1b2c@tymeslot.com_20261021T090000Z")

    MigrationRunner.replay!(@version)

    assert flag(created)
    assert flag(instance)
  end

  test "keeps a booking matched by its calendar UID or its provider event id",
       %{user: user, caldav: caldav} do
    insert(:meeting, organizer_user_id: user.id, calendar_uid: "booking-uid")

    insert(:meeting,
      organizer_user_id: user.id,
      provider_event_id: "booking-href",
      start_time: DateTime.add(DateTime.utc_now(:second), 2, :day),
      end_time: DateTime.add(DateTime.utc_now(:second), 2 * 86_400 + 3600, :second)
    )

    by_uid = cached!(caldav, uid: "booking-uid")
    by_href = cached!(caldav, uid: "other-uid", provider_event_id: "booking-href")

    MigrationRunner.replay!(@version)

    assert flag(by_uid)
    assert flag(by_href)
  end

  test "keeps a booking whose identifier the meeting holds in the other field",
       %{user: user, caldav: caldav} do
    insert(:meeting, organizer_user_id: user.id, calendar_uid: "uid-held-as-href")

    insert(:meeting,
      organizer_user_id: user.id,
      provider_event_id: "href-held-as-uid",
      start_time: DateTime.add(DateTime.utc_now(:second), 2, :day),
      end_time: DateTime.add(DateTime.utc_now(:second), 2 * 86_400 + 3600, :second)
    )

    by_meeting_uid = cached!(caldav, uid: "unrelated-uid", provider_event_id: "uid-held-as-href")
    by_meeting_href = cached!(caldav, uid: "href-held-as-uid", provider_event_id: "/cal/x.ics")

    MigrationRunner.replay!(@version)

    assert flag(by_meeting_uid)
    assert flag(by_meeting_href)
  end

  test "does not match a blank UID against a meeting's blank calendar UID",
       %{user: user, caldav: caldav} do
    insert(:meeting, organizer_user_id: user.id, calendar_uid: " ")
    foreign = cached!(caldav, uid: " ", provider_event_id: "/cal/blank.ics")

    MigrationRunner.replay!(@version)

    refute flag(foreign)
  end

  test "keeps a booking whose meeting was written through another integration",
       %{user: user, caldav: caldav} do
    previous = insert(:calendar_integration, user: user, provider: "caldav")

    insert(:meeting,
      organizer_user_id: user.id,
      calendar_integration_id: previous.id,
      calendar_uid: "moved-booking"
    )

    booking = cached!(caldav, uid: "moved-booking")

    MigrationRunner.replay!(@version)

    assert flag(booking)
  end

  test "does not match a blank provider event id against a meeting's blank one",
       %{user: user, caldav: caldav} do
    insert(:meeting, organizer_user_id: user.id, provider_event_id: "")
    foreign = cached!(caldav, uid: "f00d@example.org", provider_event_id: "")

    MigrationRunner.replay!(@version)

    refute flag(foreign)
  end

  test "leaves Google and Outlook rows alone", %{user: user} do
    google = insert(:calendar_integration, user: user, provider: "google")
    outlook = insert(:calendar_integration, user: user, provider: "outlook")

    google_row = cached!(google, uid: "abc@google.com", provider_event_id: "abc")

    outlook_row =
      cached!(outlook, uid: "040000008200E00074C5B7101A82E008", provider_event_id: "AAMk")

    MigrationRunner.replay!(@version)

    assert flag(google_row)
    assert flag(outlook_row)
  end

  test "never raises the flag on an unflagged row", %{caldav: caldav} do
    unflagged = cached!(caldav, uid: "0a1b2c@tymeslot.com", created_by_tymeslot: false)

    MigrationRunner.replay!(@version)

    refute flag(unflagged)
  end
end
