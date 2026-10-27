defmodule Tymeslot.Integrations.Calendar.ExternalEndChangeTest do
  @moduledoc """
  A host who lengthens or shortens a booked meeting in their own calendar,
  without moving its start, has the booking follow: its end, what the booking
  page offers around it, and the reminder it sends. A moved start is still
  only flagged for the host to look at, and so is one that moved together
  with the end.

  The Google API client is mocked at its behaviour; everything from the sync
  worker down to the meetings table and the booking page is real.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @event_id "booked-evt-1"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
    date = next_bookable_weekday()

    integration =
      insert(:calendar_integration, provider: "google", google_sync_token: "token", user: user)

    start_time = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        provider_event_id: @event_id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30
      )

    %{profile: profile, date: date, integration: integration, meeting: meeting}
  end

  describe "a meeting lengthened in Google" do
    test "takes the new end, and the booking page and the reminder follow", ctx do
      assert "11:00 AM" in labels(ctx)

      sync(ctx, ctx.meeting.start_time, ~T[11:30:00])

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.end_time == DateTime.new!(ctx.date, ~T[11:30:00], "Etc/UTC")
      assert updated.duration == 90
      assert updated.calendar_sync_status == nil

      # No cache clear between the two reads: the change itself must reach the
      # booking page.
      refute "11:00 AM" in labels(ctx)

      test_pid = self()

      expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_reminder_to_attendee, fn _email, details ->
        send(test_pid, {:reminder, details})
        {:ok, "sent"}
      end)

      assert :ok =
               EmailHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => ctx.meeting.id
               })

      assert_receive {:reminder, details}
      assert details.end_time == updated.end_time
      assert details.duration == 90
    end

    test "a shortened meeting frees the time it no longer takes", ctx do
      meeting = lengthen!(ctx.meeting, 90)
      refute "11:00 AM" in labels(ctx)

      sync(ctx, meeting.start_time, ~T[10:30:00])

      assert "11:00 AM" in labels(ctx)
    end

    test "moves the meeting's video room to the new end", ctx do
      Repo.update_all(
        from(m in MeetingSchema, where: m.id == ^ctx.meeting.id),
        set: [video_room_id: "room-1"]
      )

      sync(ctx, ctx.meeting.start_time, ~T[11:30:00])

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => ctx.meeting.id, "action" => "update"}
      )
    end
  end

  describe "a meeting moved in Google" do
    test "a new start is flagged for the host and the end is left alone", ctx do
      sync(ctx, DateTime.add(ctx.meeting.start_time, 3600, :second), ~T[11:30:00])

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
      assert updated.end_time == ctx.meeting.end_time
    end

    test "an end before the start is flagged, not written", ctx do
      sync(ctx, ctx.meeting.start_time, ~T[09:30:00])

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
      assert updated.end_time == ctx.meeting.end_time
    end
  end

  # A meeting booked before meetings followed calendar end changes may carry
  # an end its host changed long ago, which nothing acted on at the time.
  describe "a meeting whose calendar end already differed" do
    setup ctx do
      meeting =
        ctx.meeting |> Changeset.change(seen_calendar_end_time: nil) |> Repo.update!()

      with_video_room(meeting)
      %{meeting: meeting}
    end

    test "is left as it is, and nobody is told", ctx do
      sync(ctx, ctx.meeting.start_time, ~T[11:30:00])

      assert_unchanged(ctx.meeting)
      refute_enqueued(worker: EmailWorker)

      {:ok, reloaded} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert reloaded.calendar_sync_status == nil
      assert reloaded.ical_sequence == ctx.meeting.ical_sequence
      assert reloaded.seen_calendar_end_time == DateTime.new!(ctx.date, ~T[11:30:00], "Etc/UTC")
    end

    test "follows a change the host makes after that, and tells the attendees", ctx do
      sync(ctx, ctx.meeting.start_time, ~T[11:30:00])
      sync(ctx, ctx.meeting.start_time, ~T[12:00:00])

      new_end = DateTime.new!(ctx.date, ~T[12:00:00], "Etc/UTC")
      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.end_time == new_end
      assert updated.seen_calendar_end_time == new_end
      assert updated.ical_sequence == ctx.meeting.ical_sequence + 1

      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["action"] == "send_end_change_emails"
      assert job.args["meeting_id"] == ctx.meeting.id
    end

    test "an end put back to the meeting's own is in step again", ctx do
      sync(ctx, ctx.meeting.start_time, ~T[11:30:00])
      sync(ctx, ctx.meeting.start_time, ~T[10:30:00])

      assert_unchanged(ctx.meeting)
      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "an end stretched past any meeting's length" do
    test "is flagged for the host, not written or announced", ctx do
      sync_events(ctx, %{
        "start" => %{"dateTime" => DateTime.to_iso8601(ctx.meeting.start_time)},
        "end" => %{
          "dateTime" => DateTime.to_iso8601(DateTime.add(ctx.meeting.start_time, 3, :day))
        }
      })

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
      assert updated.end_time == ctx.meeting.end_time
      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "an end change for a meeting that no longer stands" do
    for {label, attrs} <- [
          {"cancelled", [status: "cancelled"]},
          {"waiting on a reschedule request",
           [reschedule_requested_at: ~U[2026-01-01 00:00:00Z]]},
          {"with the legacy reschedule status", [status: "reschedule_requested"]}
        ] do
      test "is not followed for a meeting #{label}", ctx do
        meeting = ctx.meeting |> Changeset.change(unquote(Macro.escape(attrs))) |> Repo.update!()
        with_video_room(meeting)

        sync(ctx, meeting.start_time, ~T[11:30:00])

        assert_unchanged(meeting)
      end
    end

    test "is not followed for a meeting whose slot has passed", ctx do
      start_time = DateTime.add(DateTime.utc_now(:second), -2, :hour)

      meeting =
        ctx.meeting
        |> Changeset.change(start_time: start_time, end_time: DateTime.add(start_time, 1800))
        |> Repo.update!()

      with_video_room(meeting)

      sync(ctx, meeting.start_time, DateTime.to_time(DateTime.add(start_time, 3600)))

      assert_unchanged(meeting)
    end

    # The sync reads the meeting, then writes; these land in between.
    test "is not written over a reschedule that landed after the read", ctx do
      read = ctx.meeting
      moved_start = DateTime.add(read.start_time, 2, :hour)

      moved =
        read
        |> Changeset.change(start_time: moved_start, end_time: DateTime.add(moved_start, 1800))
        |> Repo.update!()

      with_video_room(moved)

      assert :ok =
               Meetings.apply_external_end_change(
                 read,
                 DateTime.add(read.start_time, 90, :minute)
               )

      assert_unchanged(moved)
    end

    test "is not written over a cancellation that landed after the read", ctx do
      read = ctx.meeting
      cancelled = read |> Changeset.change(status: "cancelled") |> Repo.update!()
      with_video_room(cancelled)

      assert :ok =
               Meetings.apply_external_end_change(
                 read,
                 DateTime.add(read.start_time, 90, :minute)
               )

      assert_unchanged(cancelled)
    end
  end

  defp with_video_room(meeting) do
    Repo.update_all(from(m in MeetingSchema, where: m.id == ^meeting.id),
      set: [video_room_id: "room-1"]
    )
  end

  defp assert_unchanged(meeting) do
    {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
    assert reloaded.end_time == meeting.end_time
    assert reloaded.duration == meeting.duration
    refute_enqueued(worker: VideoSyncWorker, args: %{"meeting_id" => meeting.id})
  end

  describe "a meeting mirrored as an all-day event" do
    # 22:00 UTC is the next morning in Sydney, so the meeting's UTC date is
    # the day before the one on the host's calendar.
    setup ctx do
      ctx.profile |> Changeset.change(timezone: "Australia/Sydney") |> Repo.update!()
      start_time = DateTime.new!(Date.add(ctx.date, -1), ~T[22:00:00], "Etc/UTC")

      meeting =
        ctx.meeting
        |> Changeset.change(start_time: start_time, end_time: DateTime.add(start_time, 1800))
        |> Repo.update!()

      %{meeting: meeting}
    end

    test "on the host's day is not flagged", ctx do
      sync_all_day(ctx, ctx.date)

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.calendar_sync_status == nil
    end

    test "on another day is flagged", ctx do
      sync_all_day(ctx, Date.add(ctx.date, 1))

      {:ok, updated} = MeetingQueries.get_meeting(ctx.meeting.id)
      assert updated.calendar_sync_status == "externally_modified"
    end
  end

  defp sync_all_day(ctx, date) do
    sync_events(ctx, %{
      "start" => %{"date" => Date.to_iso8601(date)},
      "end" => %{"date" => Date.to_iso8601(Date.add(date, 1))}
    })
  end

  defp sync(ctx, start_at, end_time) do
    end_at = DateTime.new!(DateTime.to_date(start_at), end_time, "Etc/UTC")

    sync_events(ctx, %{
      "start" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(end_at)}
    })
  end

  defp sync_events(ctx, timing) do
    event =
      Map.merge(
        %{
          "id" => @event_id,
          "iCalUID" => @event_id,
          "status" => "confirmed",
          "summary" => "Booked meeting"
        },
        timing
      )

    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [event], next_sync_token: "token-2"}}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{
               "calendar_integration_id" => ctx.integration.id
             })
  end

  defp lengthen!(meeting, minutes) do
    end_time = DateTime.add(meeting.start_time, minutes, :minute)

    meeting
    |> Changeset.change(end_time: end_time, duration: minutes, seen_calendar_end_time: end_time)
    |> Repo.update!()
  end

  defp labels(ctx), do: ctx.profile |> offered(ctx.date, 30) |> Enum.map(&label/1)

  defp label(%{time: time}), do: time
  defp label(time) when is_binary(time), do: time
end
