defmodule Tymeslot.Bookings.HeldSeatsKeepSlotIntegrationTest do
  @moduledoc """
  The last confirmed seat leaving a group slot that still holds seats
  awaiting email verification, by cancelling or by moving away. The slot is
  held for verification again rather than cancelled: the held bookers keep
  their seats and their own deadlines, the organiser and the integrations
  hear the meeting is off, and the first held seat to be verified brings the
  slot back to life with a new calendar event.
  """

  # async: false: the seat broadcast and the calendar mock's stubs are shared
  # with the jobs performed here.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.Bookings.RescheduleRequestExpiry
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Bookings.Workers.RescheduleRequestExpiryWorker
  alias Tymeslot.Emails.Templates.SeatUpdateForOrganizer
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    # A move re-reads the organiser's calendar, which holds nothing.
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:ok, []}
    end)

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")

    type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 60,
        slot_interval_minutes: 30,
        max_participants: 3
      )

    insert(:webhook, user: user, events: ["meeting.created", "meeting.cancelled"])
    calendar = insert(:calendar_integration, user: user)

    date = Date.add(Date.utc_today(), 2)

    start_time =
      date |> DateTime.new!(~T[14:00:00], "America/New_York") |> DateTime.shift_zone!("Etc/UTC")

    # A slot that came to life: its calendar event and video room exist, and
    # a reminder is waiting.
    slot =
      insert(:group_meeting,
        status: :confirmed,
        email_verified_at: DateTime.utc_now(:second),
        verification_deadline_at: DateTime.utc_now(:second),
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type_id: type.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour),
        duration: 60,
        capacity: 3,
        calendar_integration_id: calendar.id,
        provider_event_id: "evt-original",
        video_room_id: "room-original",
        video_provider: "mirotalk",
        meeting_url: "https://video.example.com/room-original",
        video_room_enabled: true,
        reminders: [%{"value" => 1, "unit" => "hours"}]
      )

    Orchestrator.schedule_reminder_notifications(slot)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reminder_emails", "meeting_id" => slot.id}
    )

    confirmed = insert(:participant, meeting: slot, email: "confirmed@example.com")
    deadline = DateTime.add(DateTime.utc_now(:second), 30, :minute)

    held =
      insert(:participant,
        meeting: slot,
        email: "held@example.com",
        verification_deadline_at: deadline
      )

    stub(Tymeslot.EmailServiceMock, :send_seat_update_to_organizer, fn _kind, _email, _det ->
      {:ok, "sent"}
    end)

    %{
      user: user,
      slot: slot,
      confirmed: confirmed,
      held: held,
      deadline: deadline,
      date: date
    }
  end

  describe "the last confirmed guest cancels while a seat is held" do
    test "the slot is held again, ends for the organiser, and comes back when the held seat verifies",
         ctx do
      assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

      assert_held_again(ctx)

      assert [%{args: %{"event_type" => "meeting.cancelled"}}] =
               all_enqueued(worker: WebhookWorker)

      verify_brings_slot_back(ctx)
    end

    test "the organiser's one email says the meeting is cancelled, not that the time is free",
         ctx do
      assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

      seat_args = %{
        "action" => "send_seat_cancellation_emails",
        "meeting_id" => ctx.slot.id,
        "participant_id" => ctx.confirmed.id,
        "slot_freed" => true,
        "slot_held" => true
      }

      assert_enqueued(worker: EmailWorker, args: seat_args)

      test_pid = self()

      stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _to, _det ->
        {:ok, "sent"}
      end)

      expect(Tymeslot.EmailServiceMock, :send_seat_update_to_organizer, fn :cancelled, _to, det ->
        send(test_pid, {:organizer, det})
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, seat_args)
      assert_received {:organizer, details}

      email = SeatUpdateForOrganizer.render(:cancelled, "host@example.com", details)

      assert email.text_body =~
               "No one else has confirmed a spot on this slot, so the meeting has been cancelled."

      refute email.text_body =~ "free again"
    end

    test "the organiser is told the meeting is off, then that it is on again, never a plain booking",
         ctx do
      TestMocks.setup_email_mocks()
      test_pid = self()

      stub(Tymeslot.EmailServiceMock, :send_seat_update_to_organizer, fn variant, _to, det ->
        send(test_pid, {:organizer, variant, det})
        {:ok, "sent"}
      end)

      assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_seat_cancellation_emails",
                 "meeting_id" => ctx.slot.id,
                 "participant_id" => ctx.confirmed.id,
                 "slot_freed" => true,
                 "slot_held" => true
               })

      assert_received {:organizer, :cancelled, %{slot_held: true}}

      assert {:ok, :verified, _slot} = EmailVerification.verify_seat(ctx.held)

      seat_args = %{"meeting_id" => ctx.slot.id, "participant_id" => ctx.held.id}

      revived_args = Map.put(seat_args, "action", "send_seat_slot_revived")
      assert_enqueued(worker: EmailWorker, args: revived_args)
      assert :ok = perform_job(EmailWorker, revived_args)

      assert_received {:organizer, :revived, details}
      assert details.attendee_email == "held@example.com"

      email = SeatUpdateForOrganizer.render(:revived, "host@example.com", details)
      assert email.subject =~ "Meeting back on:"

      assert email.text_body =~
               "took a spot on this slot, so the meeting you were told had been cancelled goes ahead after all."

      # The seat's own confirmation still reaches its booker, but tells the
      # organiser nothing more.
      confirmation_args = Map.put(seat_args, "action", "send_seat_confirmation_emails")

      expect(Tymeslot.EmailServiceMock, :send_appointment_confirmation_to_attendee, fn
        "held@example.com", _details -> {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, confirmation_args)
      refute_received {:organizer, _variant, _details}
    end
  end

  # Each `CancelSeat` commits its seat's cancellation before it asks
  # `SeatRelease`, so two guests leaving at once can both have given up their
  # seats before either asks. The first to ask holds the slot again; the
  # second must find it held and leave it to its held seat, rather than
  # release that seat and cancel the slot.
  describe "the last two confirmed guests leave at once while a seat is held" do
    setup ctx do
      %{second: insert(:participant, meeting: ctx.slot, email: "second@example.com")}
    end

    test "the second release leaves the held slot and its held seat alone", ctx do
      {:ok, _cancelled} = ParticipantQueries.cancel(reload(ctx.confirmed))
      {:ok, _cancelled} = ParticipantQueries.cancel(reload(ctx.second))

      assert {:ok, :returned_to_held} = SeatRelease.release(ctx.slot)
      held_slot = reload(ctx.slot)
      assert %{status: :awaiting_verification} = held_slot

      assert {:ok, :already_held} = SeatRelease.release(ctx.slot)

      assert reload(ctx.slot) == held_slot
      assert %{cancelled_at: nil, email_verified_at: nil} = reload(ctx.held)

      refute_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => ctx.slot.id}
      )
    end

    # The second guest's cancellation is replayed through `CancelSeat` so
    # that what follows its release runs: its seat is put back live after the
    # first release, and the release it then asks meets what the interleaving
    # leaves it, its own seat given up and the slot held by the first. A held
    # slot refuses `CancelSeat.execute/1` up front, so the replay gives the
    # seat up in a transaction of its own and finishes it.
    test "only the second guest is emailed: the organiser heard from the first", ctx do
      {:ok, _cancelled} = ParticipantQueries.cancel(reload(ctx.confirmed))
      {:ok, _cancelled} = ParticipantQueries.cancel(reload(ctx.second))
      assert {:ok, :returned_to_held} = SeatRelease.release(ctx.slot)

      Repo.update_all(where(ParticipantSchema, id: ^ctx.second.id), set: [cancelled_at: nil])

      assert {:ok, %{outcome: :already_held} = released} =
               Repo.transaction(fn ->
                 {:ok, released} = CancelSeat.cancel_in_transaction(reload(ctx.second))
                 released
               end)

      assert :ok = CancelSeat.finish(released)

      assert %{status: :awaiting_verification} = reload(ctx.slot)
      assert %{cancelled_at: nil, email_verified_at: nil} = reload(ctx.held)
      assert %{cancelled_at: %DateTime{}} = reload(ctx.second)

      refute_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => ctx.slot.id}
      )

      seat_args = %{
        "action" => "send_seat_cancellation_emails",
        "meeting_id" => ctx.slot.id,
        "participant_id" => ctx.second.id,
        "slot_freed" => true,
        "slot_held" => false,
        "organizer_told" => true
      }

      assert_enqueued(worker: EmailWorker, args: seat_args)

      test_pid = self()

      stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn to, details ->
        send(test_pid, {:attendee, to, details})
        {:ok, "sent"}
      end)

      stub(Tymeslot.EmailServiceMock, :send_seat_update_to_organizer, fn kind, _to, _details ->
        send(test_pid, {:organizer, kind})
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, seat_args)

      assert_received {:attendee, "second@example.com", %{slot_freed: true}}
      refute_received {:organizer, _kind}
    end
  end

  describe "the last confirmed guest moves away while a seat is held" do
    test "the held slot still occupies its time, so an overlapping move is refused", ctx do
      assert {:error, :slot_taken} = move(ctx.confirmed, "14:30")

      assert %{status: :confirmed} = reload(ctx.slot)
      assert %{cancelled_at: nil} = reload(ctx.confirmed)
      assert %{cancelled_at: nil, email_verified_at: nil} = reload(ctx.held)
    end

    test "a move elsewhere holds the old slot again, which the held seat brings back", ctx do
      assert {:ok, %{meeting: new_meeting, created_meeting?: true}} = move(ctx.confirmed, "10:00")
      refute new_meeting.id == ctx.slot.id

      assert_held_again(ctx)

      # The mover's one email tells the organiser the earlier meeting is off,
      # though held seats keep its time.
      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_seat_reschedule_emails",
          "old_slot_freed" => true,
          "old_slot_held" => true
        }
      )

      verify_brings_slot_back(ctx)
    end
  end

  # A seat moved onto the held slot counts on it at once, so it brings the
  # slot back: the organiser hears it is on again, beside the move's own
  # email, which still tells them of the move.
  test "a guest moving onto the held slot brings it back, and the organiser hears so", ctx do
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

    other_start = DateTime.add(ctx.slot.start_time, 1, :day)

    other =
      insert(:group_meeting,
        status: :confirmed,
        organizer_user_id: ctx.slot.organizer_user_id,
        organizer_email: ctx.slot.organizer_email,
        meeting_type_id: ctx.slot.meeting_type_id,
        start_time: other_start,
        end_time: DateTime.add(other_start, 1, :hour),
        duration: 60,
        capacity: 3
      )

    mover = insert(:participant, meeting: other, email: "mover@example.com")

    assert {:ok, %{meeting: %{id: slot_id}, participant: new_seat}} = move(mover, "14:00")
    assert slot_id == ctx.slot.id
    assert reload(ctx.slot).status == :confirmed

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_slot_revived",
        "meeting_id" => ctx.slot.id,
        "participant_id" => new_seat.id
      }
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_seat_reschedule_emails", "participant_id" => new_seat.id}
    )

    # The move's email is not the revival's to suppress.
    assert %{organizer_notified_at: nil} = reload(new_seat)
  end

  # A create still queued from the slot's activation runs after the slot is
  # held again: it must not put the held slot on the organiser's calendar.
  # The calendar mock has no create stub, so a write would fail the test.
  test "a create queued before the slot was held again writes no event", ctx do
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)
    assert reload(ctx.slot).status == :awaiting_verification

    assert :ok =
             perform_job(CalendarEventWorker, %{"action" => "create", "meeting_id" => ctx.slot.id})
  end

  # The organiser was told of the meeting and then that it was cancelled, so
  # when the held seat lapses it ends cancelled in their history, and the
  # prune of holds nobody saw keeps it and the departed guest's seat.
  test "a slot held again whose held seat lapses stays in the organiser's history", ctx do
    assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

    {:ok, _released} = EmailVerification.expire_seat(ctx.held)

    assert %{status: :cancelled, cancelled_at: %DateTime{}} = reload(ctx.slot)
    assert ctx.slot.id in organiser_meeting_ids(ctx)

    past = DateTime.add(DateTime.utc_now(:second), -2, :hour)
    Repo.update_all(where(MeetingSchema, id: ^ctx.slot.id), set: [verification_deadline_at: past])

    Repo.update_all(where(ParticipantSchema, id: ^ctx.held.id),
      set: [verification_deadline_at: past]
    )

    assert {1, nil} = EmailVerification.prune_unverified(1)

    assert %{status: :cancelled} = reload(ctx.slot)
    assert %{cancelled_at: %DateTime{}} = reload(ctx.confirmed)
    refute Repo.get(ParticipantSchema, ctx.held.id)
  end

  # The host's request asked the confirmed guest, now gone, for a new time.
  # Left standing, it would void the slot's time and refuse the held seat.
  test "a reschedule request pending on the slot is cleared when it is held again", ctx do
    requested_at = DateTime.utc_now(:second)

    Repo.update_all(where(MeetingSchema, id: ^ctx.slot.id),
      set: [reschedule_requested_at: requested_at]
    )

    :ok = RescheduleRequestExpiry.schedule(reload(ctx.slot))
    assert_enqueued(worker: RescheduleRequestExpiryWorker, args: %{"meeting_id" => ctx.slot.id})

    assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

    assert %{status: :awaiting_verification, reschedule_requested_at: nil} = reload(ctx.slot)
    refute_enqueued(worker: RescheduleRequestExpiryWorker, args: %{"meeting_id" => ctx.slot.id})

    assert {:ok, :verified, %MeetingSchema{status: :confirmed}} =
             EmailVerification.verify_seat(ctx.held)
  end

  test "with no held seat left, the last guest cancelling cancels the slot", ctx do
    {:ok, _released} = EmailVerification.expire_seat(ctx.held)

    assert {:ok, :meeting_cancelled} = CancelSeat.execute(ctx.confirmed.management_token)

    assert %{status: :cancelled, calendar_uid: uid, provider_event_id: "evt-original"} =
             reload(ctx.slot)

    assert uid == ctx.slot.calendar_uid

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "delete", "meeting_id" => ctx.slot.id}
    )

    refute_enqueued(worker: CalendarEventWorker, args: %{"action" => "replace"})
  end

  defp assert_held_again(ctx) do
    held_slot = reload(ctx.slot)

    # The slot keeps the stamp of its first life, the record that the
    # organiser knew of it, and is hidden by its status alone.
    assert %{status: :awaiting_verification, cancelled_at: nil} = held_slot
    assert held_slot.email_verified_at == ctx.slot.email_verified_at

    assert held_slot.verification_deadline_at == ctx.deadline
    assert %{provider_event_id: nil, video_room_id: nil, meeting_url: nil} = held_slot
    refute held_slot.calendar_uid == ctx.slot.calendar_uid

    assert %{cancelled_at: nil, email_verified_at: nil} = reload(ctx.held)
    refute ctx.slot.id in organiser_meeting_ids(ctx)

    refute_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reminder_emails", "meeting_id" => ctx.slot.id}
    )

    assert_enqueued(
      worker: VideoSyncWorker,
      args: %{"action" => "release", "meeting_id" => ctx.slot.id, "room_id" => "room-original"}
    )

    # The original event is deleted by its own id, though the slot no longer
    # names it.
    replace_args = %{
      "action" => "replace",
      "meeting_id" => ctx.slot.id,
      "event_id" => "evt-original"
    }

    assert_enqueued(worker: CalendarEventWorker, args: replace_args)

    expect(Tymeslot.CalendarMock, :delete_event, fn "evt-original", _meeting, _opts -> :ok end)
    assert :ok = perform_job(CalendarEventWorker, replace_args)
  end

  # Verifying the held seat confirms the slot as its first counting seat: a
  # calendar event created under the slot's new identity, and the seat's
  # confirmation, which tells the organiser of the booking.
  defp verify_brings_slot_back(ctx) do
    new_uid = reload(ctx.slot).calendar_uid

    assert {:ok, :verified, %MeetingSchema{status: :confirmed}} =
             EmailVerification.verify_seat(ctx.held)

    assert %{status: :confirmed, email_verified_at: %DateTime{}} = reload(ctx.slot)

    create_args = %{"action" => "create", "meeting_id" => ctx.slot.id}
    assert_enqueued(worker: CalendarEventWorker, args: create_args)

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_seat_confirmation_emails",
        "meeting_id" => ctx.slot.id,
        "participant_id" => ctx.held.id
      }
    )

    assert ctx.slot.id in organiser_meeting_ids(ctx)

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _meeting ->
      assert event_data.uid == new_uid
      {:ok, %CreatedEvent{provider_event_id: "evt-new"}}
    end)

    assert :ok = perform_job(CalendarEventWorker, create_args)
  end

  defp organiser_meeting_ids(ctx) do
    ctx.user.id |> Meetings.list_upcoming_meetings_for_organizer() |> Enum.map(& &1.id)
  end

  defp move(participant, time) do
    params = %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), if(time == "10:00", do: 3, else: 2))),
      time: time,
      duration: "60min",
      user_timezone: "America/New_York"
    }

    organizer_user_id = Repo.get!(MeetingSchema, participant.meeting_id).organizer_user_id
    RescheduleSeat.execute(participant.management_token, params, organizer_user_id)
  end

  defp reload(%MeetingSchema{id: id}), do: Repo.get!(MeetingSchema, id)
  defp reload(%ParticipantSchema{id: id}), do: Repo.get!(ParticipantSchema, id)
end
