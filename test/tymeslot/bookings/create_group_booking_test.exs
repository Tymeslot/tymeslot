defmodule Tymeslot.Bookings.CreateGroupBookingTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers, only: [expect_mirotalk_success: 0]

  alias Tymeslot.Bookings.Create
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    # The booking path asks the calendar module for the meeting type's
    # destination; these tests have no calendar integration, so stub it away.
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    profile = insert(:profile, user: user)

    # The subject here is group seating, not availability, so the host offers
    # whatever time the fixture picks and the schedule is never the reason a
    # booking is refused.
    _schedule = open_schedule_for(profile)

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

  describe "video rooms" do
    setup ctx do
      integration = insert(:video_integration, user: ctx.user, provider: "mirotalk")

      {:ok, meeting_type} =
        MeetingTypes.update_meeting_type(ctx.meeting_type, %{
          allow_video: true,
          video_integration_id: integration.id
        })

      %{meeting_type: meeting_type}
    end

    # A group meeting with a video provider used to get no room at all: the
    # group branch ran before the branch that schedules one, so every
    # participant was sent an invite with nowhere to join.
    test "the first seat schedules the room and lets the worker release the emails", ctx do
      assert {:ok, meeting} = execute(ctx, "one@example.com")

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => true}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_seat_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "a later seat emails immediately and schedules no second room", ctx do
      {:ok, meeting} = execute(ctx, "one@example.com")

      assert {:ok, %{id: joined_id}} = execute(ctx, "two@example.com")
      assert joined_id == meeting.id

      assert [_only_one] =
               Enum.filter(
                 all_enqueued(worker: VideoRoomWorker),
                 &(&1.args["meeting_id"] == meeting.id)
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_seat_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    # A group meeting type with an auto-creating video provider used to never
    # send the first booker a confirmation: the room worker released a
    # solo-shaped `meeting.created` event against a meeting with no
    # `attendee_*` fields of its own, which `ContentBuilder.validate_content/2`
    # then refused as missing fields. Running the real job end to end is the
    # point — a hand-called helper would not have caught that.
    test "the first booker's confirmation reaches them once the room worker runs for real", ctx do
      assert {:ok, meeting} = execute(ctx, "one@example.com")
      assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

      expect_mirotalk_success()

      assert :ok =
               perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id, "announce" => true})

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_seat_confirmation_emails",
          "meeting_id" => meeting.id,
          "participant_id" => participant.id
        }
      )

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn attendee_email,
                                                                              _details ->
        assert attendee_email == "one@example.com"
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_seat_confirmation_emails",
                 "meeting_id" => meeting.id,
                 "participant_id" => participant.id
               })
    end

    # The same missing-attendee `meeting.created` used to fan out a SECOND
    # time once the room existed, on top of the one `seat_booked/4` already
    # sent at booking time.
    test "the room worker never re-dispatches meeting.created for a group meeting", ctx do
      {:ok, _webhook} =
        Webhooks.create_webhook(ctx.user.id, %{
          name: "Bookings",
          url: "https://example.com/hooks/bookings",
          events: ["meeting.created"]
        })

      assert {:ok, meeting} = execute(ctx, "one@example.com")
      assert length(all_enqueued(worker: WebhookWorker)) == 1

      expect_mirotalk_success()

      assert :ok =
               perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id, "announce" => true})

      assert length(all_enqueued(worker: WebhookWorker)) == 1
    end
  end

  describe "video rooms on providers outside the auto-create allow-list" do
    # Zoom does not auto-create a room (no API-driven creation for it), so the
    # group path fell back to `Policy.auto_creates_video_room?/1`'s allow-list
    # and never scheduled one at all — even though the solo path honours an
    # explicit `:with_video_room` opt for exactly this case.
    test "a Zoom-configured meeting type still gets a room when the caller opts in", ctx do
      integration = insert(:video_integration, user: ctx.user, provider: "zoom")

      {:ok, _meeting_type} =
        MeetingTypes.update_meeting_type(ctx.meeting_type, %{
          allow_video: true,
          video_integration_id: integration.id
        })

      assert {:ok, meeting} =
               Create.execute(ctx.meeting_params, form_data("zoom@example.com"),
                 skip_calendar_check: true,
                 with_video_room: true
               )

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => true}
      )
    end
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
