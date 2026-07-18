defmodule Tymeslot.Bookings.CreateGroupBookingTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker

  setup do
    # The booking path asks the calendar module for the meeting type's
    # destination; these tests have no calendar integration, so stub it away.
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    _profile = insert(:profile, user: user)

    meeting_type =
      insert(:meeting_type, user: user, max_participants: 2, allow_guests: true)

    date = Date.add(Date.utc_today(), 5)

    meeting_params = %{
      date: date,
      time: "10:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    %{user: user, meeting_type: meeting_type, meeting_params: meeting_params}
  end

  defp form_data(email) do
    %{"name" => "Booker #{email}", "email" => email, "message" => "hello"}
  end

  defp execute(ctx, email, extra_params \\ %{}) do
    Create.execute(
      Map.merge(ctx.meeting_params, extra_params),
      form_data(email),
      skip_calendar_check: true
    )
  end

  test "first group booking creates the meeting, participant, and a calendar create job",
       ctx do
    assert {:ok, meeting} = execute(ctx, "one@example.com")

    assert meeting.attendee_email == nil
    assert meeting.attendee_name == nil
    assert meeting.title == ctx.meeting_type.name
    assert meeting.status == "confirmed"

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.email == "one@example.com"
    assert participant.custom_field_answers == %{}

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "create", "meeting_id" => meeting.id}
    )
  end

  test "second booker joins the same meeting and a calendar update job is enqueued", ctx do
    {:ok, meeting} = execute(ctx, "one@example.com")

    assert {:ok, joined} = execute(ctx, "two@example.com")
    assert joined.id == meeting.id
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
    assert length(Repo.all(MeetingSchema)) == 1

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  test "a full slot surfaces as :slot_taken", ctx do
    {:ok, _meeting} = execute(ctx, "one@example.com")
    {:ok, _joined} = execute(ctx, "two@example.com")

    assert {:error, :slot_taken} = execute(ctx, "three@example.com")
  end

  test "guests consume seats and are linked to the participant", ctx do
    assert {:ok, meeting} =
             execute(ctx, "host@example.com", %{guest_emails: ["guest@example.com"]})

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    guests = Guests.list_for_meeting(meeting.id)
    assert [%{email: "guest@example.com", participant_id: participant_id}] = guests
    assert participant_id == participant.id

    assert {:error, :slot_taken} = execute(ctx, "late@example.com")
  end

  test "a committed group booking broadcasts a seat update and invalidates the cache",
       ctx do
    type_id = ctx.meeting_type.id
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(type_id))

    cache_key =
      AvailabilityCache.availability_range_key(
        ctx.user.id,
        Date.utc_today(),
        Date.add(Date.utc_today(), 41),
        "Etc/UTC",
        30
      )

    AvailabilityCache.put(cache_key, {:ok, %{"seeded" => true}})

    assert {:ok, _meeting} = execute(ctx, "one@example.com")

    assert_receive {:seat_update, ^type_id}
    assert AvailabilityCache.get_or_compute(cache_key, fn -> :recomputed end) == :recomputed
  end

  test "a failed group booking broadcasts nothing", ctx do
    type_id = ctx.meeting_type.id
    {:ok, _meeting} = execute(ctx, "one@example.com")
    {:ok, _joined} = execute(ctx, "two@example.com")

    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(type_id))
    assert {:error, :slot_taken} = execute(ctx, "three@example.com")

    refute_receive {:seat_update, ^type_id}, 100
  end
end
