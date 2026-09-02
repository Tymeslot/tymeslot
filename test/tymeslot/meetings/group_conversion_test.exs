defmodule Tymeslot.Meetings.GroupConversionTest do
  @moduledoc """
  Coverage for the solo -> group migration that runs when a meeting type
  gains a participant limit above 1.

  The bookings taken while the type was solo live in the meeting row's
  `attendee_*` columns, which seat maths cannot see. Left alone, the sitting
  attendee's seat reads as free and the next booker joins their 1:1.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.GroupConversion
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Workers.EmailWorker

  # The conversion now runs off the request path: `update_meeting_type/3`
  # only enqueues `Tymeslot.Workers.GroupConversionWorker`. Draining the
  # queue runs it synchronously so tests can assert on the result, mirroring
  # the "worker chain" pattern for A-enqueues-B coverage.
  defp run_pending_conversion do
    assert %{success: success, failure: 0} = Oban.drain_queue(queue: :default)
    success
  end

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 1)

    meeting =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          attendee_name: "Solo Booker",
          attendee_email: "solo@example.com",
          attendee_timezone: "Europe/Berlin"
        ] ++ slot_in(3)
      )

    %{user: user, meeting_type: meeting_type, meeting: meeting}
  end

  # The meetings table checks end_time > start_time, so both move together.
  defp slot_in(days) do
    start_time = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)]
  end

  test "switching a type to group bookings gives its bookings a seat",
       %{meeting_type: meeting_type, meeting: meeting} do
    # No participant row exists yet, but the sitting attendee still holds the
    # slot: `Tymeslot.Meetings.ParticipantQueries.count_seats_taken/1` counts
    # an unconverted attendee as one seat taken, precisely so this slot does
    # not read as free the moment the type becomes group but before the
    # conversion job has run — see the conversion-window test below.
    assert Seats.seats_taken(meeting.id) == 1

    {:ok, updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.name == "Solo Booker"
    assert participant.email == "solo@example.com"
    assert participant.timezone == "Europe/Berlin"
    assert participant.management_token

    # The sitting booking now occupies a seat, so only three remain.
    assert Seats.seats_left(meeting, updated.max_participants) == 3
  end

  test "the existing booking's guests are adopted so they count too",
       %{meeting_type: meeting_type, meeting: meeting} do
    {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["plus-one@example.com"])

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert [%{email: "plus-one@example.com"}] = GuestQueries.list_for_participant(participant.id)
    assert Seats.seats_taken(meeting.id) == 2
  end

  test "raising an already-group limit converts nothing", %{user: user} do
    group_type = insert(:meeting_type, user: user, max_participants: 3)

    meeting =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: group_type,
          attendee_name: nil,
          attendee_email: nil
        ] ++ slot_in(5)
      )

    {:ok, _updated} = MeetingTypes.update_meeting_type(group_type, %{max_participants: 8})
    run_pending_conversion()

    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  test "past bookings are left alone", %{user: user, meeting_type: meeting_type} do
    past =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          attendee_name: "Last Week",
          attendee_email: "past@example.com"
        ] ++ slot_in(-7)
      )

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert ParticipantQueries.list_live_for_meeting(past.id) == []
  end

  test "converting twice does not double up", %{meeting_type: meeting_type, meeting: meeting} do
    {:ok, _first} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()
    assert {:ok, 0} = GroupConversion.backfill(meeting_type.id, 4)

    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end

  test "the converted meeting's own capacity is snapshotted, not just its participant",
       %{meeting_type: meeting_type, meeting: meeting} do
    assert meeting.capacity == 1

    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert {:ok, %{capacity: 4}} = MeetingQueries.get_meeting(meeting.id)
  end

  # This is the exploit: the type flips to group synchronously with the
  # save, but the sitting attendee has no participant row until the worker
  # (enqueued in the same transaction, but run off the request path) has had
  # a chance to run. In that window a stranger must still be refused the
  # slot, not handed the sitting attendee's seat.
  test "the conversion window refuses a stranger the sitting attendee's seat",
       %{user: user, meeting_type: meeting_type, meeting: meeting} do
    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})

    # The job is enqueued but deliberately not drained: this is the window.
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
    assert {:ok, %{capacity: 1}} = MeetingQueries.get_meeting(meeting.id)

    attrs = %{
      uid: UUID.generate(),
      title: meeting_type.name,
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      duration: meeting_type.duration_minutes,
      status: "confirmed",
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser@example.com",
      meeting_type_id: meeting_type.id
    }

    seat_request = %{
      participant: %{
        name: "Stranger",
        email: "stranger@example.com",
        timezone: "Etc/UTC",
        locale: "en",
        custom_field_answers: %{}
      },
      guest_emails: [],
      max_participants: 4
    }

    assert {:error, :slot_full} = GroupScheduling.book_seat(attrs, seat_request)

    # Nobody joined, and the sitting attendee's own eventual conversion is
    # still intact and waiting for the worker.
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
    assert {:ok, %{capacity: 1}} = MeetingQueries.get_meeting(meeting.id)

    run_pending_conversion()

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.email == "solo@example.com"
  end

  test "a converted booker is delivered a seat confirmation carrying their management link",
       %{meeting_type: meeting_type, meeting: meeting} do
    {:ok, _updated} = MeetingTypes.update_meeting_type(meeting_type, %{max_participants: 4})
    run_pending_conversion()

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_confirmation_emails",
        "meeting_id" => meeting.id,
        "participant_id" => participant.id
      }
    )
  end

  test "a capacity correction shortly after the first save re-stamps the converted meeting",
       %{meeting_type: meeting_type, meeting: meeting} do
    assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 10)
    assert {:ok, %{capacity: 10}} = MeetingQueries.get_meeting(meeting.id)
    assert [participant_after_first] = ParticipantQueries.list_live_for_meeting(meeting.id)

    # The organiser corrects the limit before anyone else has booked in.
    assert {:ok, 0} = GroupConversion.backfill(meeting_type.id, 3)
    assert {:ok, %{capacity: 3}} = MeetingQueries.get_meeting(meeting.id)

    # Re-stamping never touches the participant itself, nor duplicates it.
    assert [participant_after_second] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant_after_second.id == participant_after_first.id
  end

  test "a meeting with a real second booker is never re-capacitated",
       %{meeting_type: meeting_type, meeting: meeting} do
    assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 4)

    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    {:ok, _second} =
      ParticipantQueries.insert(%{
        meeting_id: meeting.id,
        name: "Second Booker",
        email: "second@example.com",
        timezone: "Etc/UTC",
        locale: "en",
        custom_field_answers: %{}
      })

    assert {:ok, 0} = GroupConversion.backfill(meeting_type.id, 3)
    assert {:ok, %{capacity: 4}} = MeetingQueries.get_meeting(meeting.id)
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
    assert hd(ParticipantQueries.list_live_for_meeting(meeting.id)).id == participant.id
  end

  test "a legacy row with no attendee timezone falls back to the organiser's own timezone",
       %{user: user, meeting_type: meeting_type, meeting: meeting} do
    {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_timezone(profile, "Asia/Tokyo")

    {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{attendee_timezone: nil})

    assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 4)

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.timezone == "Asia/Tokyo"
  end

  # A row that still cannot convert even with the timezone fallback (no
  # attendee name at all, here) must not roll back the rest of the batch —
  # that is the batch-wide poisoning this test guards against.
  test "one unconvertible booking is skipped, logged, and does not poison the rest of the batch",
       %{user: user, meeting_type: meeting_type, meeting: good_meeting} do
    poisoned =
      insert(
        :meeting,
        [
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          attendee_name: nil,
          attendee_email: "poisoned@example.com"
        ] ++ slot_in(4)
      )

    assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 4)

    assert ParticipantQueries.list_live_for_meeting(poisoned.id) == []

    assert [%{email: "solo@example.com"}] =
             ParticipantQueries.list_live_for_meeting(good_meeting.id)
  end

  test "conversion invalidates the organiser's cached availability and broadcasts the seat change",
       %{user: user, meeting_type: meeting_type, meeting: meeting} do
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, "group_seats:#{meeting_type.id}")

    cache_key =
      AvailabilityCache.availability_range_key(
        user.id,
        Date.utc_today(),
        Date.add(Date.utc_today(), 41),
        "Etc/UTC",
        30
      )

    AvailabilityCache.put(cache_key, {:ok, %{"seeded" => true}})

    assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 4)

    assert AvailabilityCache.get_or_compute(cache_key, fn -> :recomputed end) == :recomputed
    assert_receive {:seat_update, _meeting_type_id}
    refute ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end
end
