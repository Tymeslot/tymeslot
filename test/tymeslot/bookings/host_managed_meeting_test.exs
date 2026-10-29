defmodule Tymeslot.Bookings.HostManagedMeetingTest do
  @moduledoc """
  A meeting confirmed from a poll is managed by its host: it has no booker.
  The person in its attendee fields is a guest like everyone else, is sent no
  booking emails, and cannot move or cancel the meeting; the host moves it
  from the dashboard.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Bookings.{Cancel, HostMove, Orchestrator, Reschedule, RescheduleRequest}
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.{GuestQueries, Guests, GuestSchema, MeetingSchema}
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_email: "ada@example.com",
        status: :confirmed,
        managed_by_host: true,
        meeting_type_id: nil,
        organizer_email_sent: false,
        attendee_email_sent: false
      )

    {:ok, guests} =
      Guests.create_for_meeting(meeting.id, ["ada@example.com", "bob@example.com"], :organizer)

    %{user: user, profile: profile, meeting: meeting, guests: guests}
  end

  # The host's copy is about the meeting and its guests: nobody booked it
  # (`AppointmentBuilder.organizer_copy/2`).
  defp assert_host_copy(details, meeting) do
    assert details.host_managed
    assert details.attendee_name == meeting.title
    assert details.attendee_email == nil

    assert details.guests == [
             %{name: nil, email: "ada@example.com"},
             %{name: nil, email: "bob@example.com"}
           ]

    assert details.cancel_url == nil
    assert details.reschedule_url == nil
  end

  describe "emails" do
    test "the confirmation goes to the host and every guest, never as a booking", ctx do
      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, details ->
        assert_host_copy(details, ctx.meeting)
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_confirmation, 2, fn email, details ->
        assert email in ["ada@example.com", "bob@example.com"]
        assert details.guest_decline_url
        {:ok, "sent"}
      end)

      assert :ok =
               EmailHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => ctx.meeting.id
               })

      assert GuestQueries.list_unsent_for_meeting(ctx.meeting.id) == []
    end

    test "reminders go to the host and the guests", ctx do
      Repo.update_all(
        from(g in GuestSchema, where: g.meeting_id == ^ctx.meeting.id),
        set: [confirmation_sent_at: DateTime.utc_now(:second)]
      )

      expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, details ->
        assert_host_copy(details, ctx.meeting)
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_reminder, 2, fn _email, _details -> {:ok, "sent"} end)

      assert :ok =
               EmailHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => ctx.meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })
    end

    test "a cancellation goes to the host and the guests", ctx do
      Repo.update!(
        Changeset.change(ctx.meeting,
          status: :cancelled,
          first_announced_at: DateTime.utc_now(:second)
        )
      )

      expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, details ->
        assert_host_copy(details, ctx.meeting)
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_cancellation, 2, fn _email, _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => ctx.meeting.id
               })
    end
  end

  describe "the person in the attendee fields" do
    test "cannot cancel it from the public page, the host can", ctx do
      assert {:error, :managed_by_host} = Cancel.validate_cancellation(ctx.meeting)
      assert :ok = Cancel.validate_cancellation(ctx.meeting, caller: :organizer)
    end

    test "is not given the booking page's reschedule form", ctx do
      assert {:error, :managed_by_host} =
               Orchestrator.get_meeting_for_reschedule(ctx.meeting.uid, ctx.user.id)
    end

    test "cannot move it through the booking page", ctx do
      assert {:error, :managed_by_host} =
               Reschedule.execute(ctx.meeting.uid, %{}, ctx.user.id)
    end

    test "is not asked by the host to pick a new time", ctx do
      assert {:error, :managed_by_host} = RescheduleRequest.send_reschedule_request(ctx.meeting)
    end
  end

  describe "HostMove.move/3" do
    test "moves the meeting, keeping its length, and tells the host and every guest", ctx do
      Repo.update_all(
        from(g in GuestSchema, where: g.meeting_id == ^ctx.meeting.id),
        set: [status: :accepted]
      )

      new_start = DateTime.add(ctx.meeting.start_time, 2, :day)

      expect(EmailServiceMock, :send_reschedule_email_to_organizer, fn _email, details ->
        assert DateTime.compare(details.original_start_time, ctx.meeting.start_time) == :eq
        assert_host_copy(details, ctx.meeting)
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_guest_reschedule, 2, fn _email, _details -> {:ok, "sent"} end)

      assert {:ok, moved} = HostMove.move(ctx.meeting.uid, new_start, ctx.user.id)

      # The notices go out from the reschedule job, as for any move.
      assert [job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_reschedule_emails", "meeting_id" => ctx.meeting.id}
               )

      assert :ok = perform_job(EmailWorker, job.args)

      assert moved.start_time == new_start

      assert DateTime.diff(moved.end_time, moved.start_time) ==
               DateTime.diff(ctx.meeting.end_time, ctx.meeting.start_time)

      assert moved.ical_sequence == ctx.meeting.ical_sequence + 1

      # Everyone is asked again whether they can come.
      assert ctx.meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.status) ==
               [:pending, :pending]
    end

    test "refuses a time the host already has another meeting at", ctx do
      new_start = DateTime.add(ctx.meeting.start_time, 2, :day)

      insert(:meeting,
        organizer_user: ctx.user,
        organizer_email: ctx.user.email,
        status: :confirmed,
        start_time: new_start,
        end_time: DateTime.add(new_start, 30, :minute)
      )

      assert {:error, :slot_taken} =
               HostMove.move(ctx.meeting.uid, new_start, ctx.user.id)

      assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
    end

    test "is not held to the host's booking limits, which govern what bookers pick", ctx do
      Repo.update!(Changeset.change(ctx.profile, max_bookings_per_day: 1, timezone: "Etc/UTC"))
      day = Date.add(Date.utc_today(), 5)

      insert(:meeting,
        organizer_user: ctx.user,
        organizer_email: ctx.user.email,
        status: :confirmed,
        start_time: DateTime.new!(day, ~T[09:00:00], "Etc/UTC"),
        end_time: DateTime.new!(day, ~T[10:00:00], "Etc/UTC")
      )

      new_start = DateTime.new!(day, ~T[14:00:00], "Etc/UTC")

      assert {:ok, moved} = HostMove.move(ctx.meeting.uid, new_start, ctx.user.id)
      assert moved.start_time == new_start
    end

    test "is not padded by the host's buffers: only a meeting at that time refuses it", ctx do
      insert(:availability_schedule,
        profile: ctx.profile,
        is_default: true,
        buffer_before_minutes: 15,
        buffer_after_minutes: 15
      )

      other_start = DateTime.add(ctx.meeting.start_time, 2, :day)

      other =
        insert(:meeting,
          organizer_user: ctx.user,
          organizer_email: ctx.user.email,
          status: :confirmed,
          start_time: other_start,
          end_time: DateTime.add(other_start, 30, :minute)
        )

      # Back to back with `other`: inside the 15 minutes a booker's time is
      # padded by.
      assert {:ok, moved} = HostMove.move(ctx.meeting.uid, other.end_time, ctx.user.id)
      assert moved.start_time == other.end_time
    end

    test "refuses a time inside the host's time off, as confirming the poll does", ctx do
      Repo.update!(Changeset.change(ctx.profile, timezone: "Etc/UTC"))
      day = Date.add(Date.utc_today(), 5)
      {:ok, _period} = TimeOff.create(ctx.profile.id, %{starts_on: day, ends_on: day})

      assert {:error, :time_off} =
               HostMove.move(
                 ctx.meeting.uid,
                 DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
                 ctx.user.id
               )

      assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})
    end

    test "moves onto the day before the host's time off", ctx do
      Repo.update!(Changeset.change(ctx.profile, timezone: "Etc/UTC"))
      day = Date.add(Date.utc_today(), 5)
      {:ok, _period} = TimeOff.create(ctx.profile.id, %{starts_on: day, ends_on: day})
      new_start = DateTime.new!(Date.add(day, -1), ~T[10:00:00], "Etc/UTC")

      assert {:ok, moved} = HostMove.move(ctx.meeting.uid, new_start, ctx.user.id)
      assert moved.start_time == new_start
    end

    test "refuses a time that has started", ctx do
      assert {:error, :slot_in_past} =
               HostMove.move(
                 ctx.meeting.uid,
                 DateTime.add(DateTime.utc_now(), -1, :hour),
                 ctx.user.id
               )
    end

    test "refuses the time it already has, so nobody is told of a move or asked again", ctx do
      Repo.update_all(
        from(g in GuestSchema, where: g.meeting_id == ^ctx.meeting.id),
        set: [status: :accepted]
      )

      assert {:error, :same_time} =
               HostMove.move(ctx.meeting.uid, ctx.meeting.start_time, ctx.user.id)

      assert all_enqueued(worker: EmailWorker) == []

      assert Repo.get!(MeetingSchema, ctx.meeting.id).ical_sequence == ctx.meeting.ical_sequence

      assert ctx.meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.status) ==
               [:accepted, :accepted]
    end

    test "is not for a meeting with a booker, who moves it themselves", ctx do
      start = DateTime.add(ctx.meeting.start_time, 3, :day)

      booked =
        insert(:meeting,
          organizer_user: ctx.user,
          organizer_email: ctx.user.email,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute)
        )

      assert {:error, :not_managed_by_host} =
               HostMove.move(
                 booked.uid,
                 DateTime.add(booked.start_time, 1, :day),
                 ctx.user.id
               )
    end

    test "does not reach another host's meeting", ctx do
      assert {:error, :meeting_not_found} =
               HostMove.move(
                 ctx.meeting.uid,
                 DateTime.add(ctx.meeting.start_time, 1, :day),
                 insert(:user).id
               )
    end
  end
end
