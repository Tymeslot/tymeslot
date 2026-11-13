defmodule Tymeslot.BookingSeries.NotificationsTest do
  @moduledoc """
  A booked series is confirmed once, to its booker and its organiser, with
  every session listed: through the series' announcement job, which waits
  for the sessions' video rooms, and the email job it queues.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails
  @moduletag :integration

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SeriesAnnouncementWorker

  @german_months ~w(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    # The real email service, so the rendered emails reach this process.
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    host =
      create_always_bookable_profile(
        timezone: "Etc/UTC",
        profile: %{username: "grace-host", full_name: "Grace Hopper"}
      )

    %{host: host, today: Date.utc_today()}
  end

  defp series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          name: "Mentoring",
          duration_minutes: 30,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  defp at(today, days), do: today |> Date.add(days) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

  defp weekly(today, count), do: %{mode: :recurring, first_start: at(today, 7), count: count}

  defp book(host, type, series, params \\ %{}, opts \\ []) do
    %{
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: host.user.id,
      meeting_type_id: type.id,
      series: series
    }
    |> Map.merge(params)
    |> BookingSeries.book(
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""},
      opts
    )
  end

  defp announce(series, opts \\ []),
    do: perform_job(SeriesAnnouncementWorker, %{"series_id" => series.id}, opts)

  defp drain_emails, do: Oban.drain_queue(queue: :emails, with_recursion: true)

  defp series_jobs,
    do: all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_confirmation"})

  # The two series emails, the booker's first.
  defp sent_pair do
    assert_received {:email, first}
    assert_received {:email, second}
    refute_received {:email, _third}

    {[attendee], [organizer]} =
      Enum.split_with([first, second], &(&1.to == [{"Ada Lovelace", "ada@example.com"}]))

    {attendee, organizer}
  end

  defp ics(email), do: Enum.find(email.attachments, &(&1.content_type == "text/calendar"))

  defp ics_uids(data) do
    ~r/^UID:([^@\r\n]+)@/m
    |> Regex.scan(data)
    |> Enum.map(fn [_line, uid] -> uid end)
  end

  defp meetings,
    do: Repo.all(from(m in MeetingSchema, order_by: m.series_position))

  test "one confirmation for a series, none per meeting", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 4))

    assert [_announcement] =
             all_enqueued(worker: SeriesAnnouncementWorker, args: %{"series_id" => series.id})

    assert %{success: 2} = drain_emails()

    {attendee, organizer} = sent_pair()

    assert attendee.subject == "Your 4 sessions with Grace Hopper are booked"
    assert organizer.subject == "Ada Lovelace booked 4 sessions"
    assert organizer.to == [{"Grace Hopper", host.user.email}]

    for position <- 1..4 do
      assert attendee.text_body =~ "Session #{position} of 4"
      assert organizer.text_body =~ "Session #{position} of 4"
    end

    # Each session's own links for the booker, and the whole series' page.
    for meeting <- meetings() do
      assert attendee.text_body =~ "/grace-host/meeting/#{meeting.uid}/reschedule"
      assert attendee.text_body =~ "/grace-host/meeting/#{meeting.uid}/cancel"
      assert organizer.text_body =~ "/dashboard/meetings?meeting=#{meeting.id}"
    end

    assert attendee.text_body =~ "/grace-host/series/#{series.uid}"
    assert attendee.html_body =~ "Every week on #{weekday(at(today, 7))}"
    assert ics(attendee).filename == "series-#{series.uid}.ics"
    assert ics(organizer) == nil

    assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"}) ==
             []
  end

  test "the attachment holds one event per session", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, _booked} = book(host, type, weekly(today, 4))
    drain_emails()
    {attendee, _organizer} = sent_pair()

    data = ics(attendee).data
    uids = ics_uids(data)

    assert length(Regex.scan(~r/^BEGIN:VEVENT/m, data)) == 4
    assert uids == Enum.map(meetings(), & &1.calendar_uid)
    assert uids |> Enum.uniq() |> length() == 4
    refute data =~ "RRULE"
  end

  describe "video rooms" do
    setup %{host: host} do
      video = insert(:video_integration, user: host.user, provider: "mirotalk")
      type = series_type(host, allow_video: true, video_integration_id: video.id)
      %{type: type}
    end

    test "waits for video rooms", %{host: host, today: today, type: type} do
      assert {:ok, %{series: series}} =
               book(host, type, weekly(today, 3), %{}, with_video_room: true)

      assert {:snooze, 30} = announce(series)
      assert series_jobs() == []

      # What `VideoRoomWorker` writes once a room exists.
      for meeting <- meetings() do
        meeting
        |> Changeset.change(
          video_room_id: "room-#{meeting.series_position}",
          meeting_url: "https://video.example.com/room-#{meeting.series_position}",
          attendee_video_url: "https://video.example.com/room-#{meeting.series_position}?p=ada"
        )
        |> Repo.update!()
      end

      assert :ok = announce(series)
      drain_emails()
      {attendee, _organizer} = sent_pair()

      for position <- 1..3 do
        assert attendee.text_body =~ "https://video.example.com/room-#{position}?p=ada"
      end

      refute attendee.text_body =~ "The join link will be in your reminder."
    end

    test "a room job that gave up stops the wait at once", %{
      host: host,
      today: today,
      type: type
    } do
      assert {:ok, %{series: series}} =
               book(host, type, weekly(today, 2), %{}, with_video_room: true)

      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Tymeslot.Workers.VideoRoomWorker"),
        set: [state: "discarded"]
      )

      assert :ok = announce(series)
      drain_emails()
      {attendee, _organizer} = sent_pair()

      assert attendee.text_body =~ "The join link will be in your reminder."
    end

    test "still waits after 19 snoozes", %{host: host, today: today, type: type} do
      assert {:ok, %{series: series}} =
               book(host, type, weekly(today, 2), %{}, with_video_room: true)

      assert {:snooze, 30} = announce(series, meta: %{"snoozed" => 19})
      assert series_jobs() == []
    end

    test "sends without a link after the wait runs out", %{host: host, today: today, type: type} do
      assert {:ok, %{series: series}} =
               book(host, type, weekly(today, 3), %{}, with_video_room: true)

      log =
        capture_log(fn ->
          assert :ok = announce(series, meta: %{"snoozed" => 20})
        end)

      assert log =~ "Sending the series confirmation without every video room"

      drain_emails()
      {attendee, _organizer} = sent_pair()

      assert length(String.split(attendee.text_body, "The join link will be in your reminder.")) ==
               4
    end
  end

  test "scheduling the confirmation twice returns the job already queued", %{
    host: host,
    today: today
  } do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 2))

    assert [queued] =
             all_enqueued(worker: SeriesAnnouncementWorker, args: %{"series_id" => series.id})

    assert {:ok, %Oban.Job{id: id, conflict?: true}} =
             Notifications.schedule_series_confirmation(series)

    assert id == queued.id
  end

  test "a confirmation already sent is not queued again", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 2))

    drain_emails()
    {_attendee, _organizer} = sent_pair()

    # The announcement run again, as after a rescue: the completed email job
    # stands in for the one it would queue.
    assert :ok = Notifications.send_series_confirmation(series)
    assert %{success: 0} = drain_emails()
    refute_received {:email, _again}
  end

  test "a retry resends only the email that failed", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 2))
    assert :ok = announce(series)

    Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    [queued] = series_jobs()
    # The stored job, so both runs share its id as a rescued or retried job
    # does, which is what each send is claimed on.
    job = %{Repo.get!(Oban.Job, queued.id) | attempt: 1, attempted_at: DateTime.utc_now()}

    expect(Tymeslot.EmailServiceMock, :send_series_confirmation, 2, fn
      :attendee, "ada@example.com", _details -> {:ok, :sent}
      :organizer, _email, _details -> {:error, :smtp_down}
    end)

    assert {:error, _reason} = perform_job(job)

    expect(Tymeslot.EmailServiceMock, :send_series_confirmation, 1, fn
      :organizer, _email, _details -> {:ok, :sent}
    end)

    assert :ok = perform_job(%{job | attempt: 2})
  end

  test "a session cancelled before the confirmation is shown cancelled", %{
    host: host,
    today: today
  } do
    type = series_type(host)

    assert {:ok, %{series: series, meetings: [_first, second, _third]}} =
             book(host, type, weekly(today, 3))

    second |> Changeset.change(status: :cancelled) |> Repo.update!()

    assert :ok = announce(series)
    drain_emails()
    {attendee, organizer} = sent_pair()

    assert attendee.subject == "Your 3 sessions with Grace Hopper are booked"
    assert organizer.subject == "Ada Lovelace booked 3 sessions"

    [_before, cancelled_card, _after] =
      String.split(attendee.text_body, ["Session 2 of 3", "Session 3 of 3"])

    assert cancelled_card =~ "This session has been cancelled."
    refute cancelled_card =~ second.uid
    assert length(String.split(attendee.text_body, "This session has been cancelled.")) == 2

    data = ics(attendee).data
    refute data =~ "UID:#{second.calendar_uid}@"
    assert length(Regex.scan(~r/^BEGIN:VEVENT/m, data)) == 2
  end

  test "a cancelled series sends nothing", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 3))

    series
    |> SeriesSchema.cancel_changeset(DateTime.utc_now())
    |> Repo.update!()

    assert :ok = announce(series)
    assert series_jobs() == []
  end

  test "a series gone before its announcement discards the job" do
    assert {:discard, "Series not found"} =
             perform_job(SeriesAnnouncementWorker, %{"series_id" => UUID.generate()})
  end

  test "a series whose every session was cancelled sends nothing", %{host: host, today: today} do
    type = series_type(host)
    assert {:ok, %{series: series}} = book(host, type, weekly(today, 2))

    Repo.update_all(MeetingSchema, set: [status: :cancelled])

    assert :ok = announce(series)
    assert series_jobs() == []
  end

  test "a group series email carries seat links", %{host: host, today: today} do
    type = series_type(host, max_participants: 3)
    assert {:ok, %{series: series, participants: seats}} = book(host, type, weekly(today, 3))

    assert :ok = announce(series)
    drain_emails()
    {attendee, organizer} = sent_pair()

    assert length(seats) == 3

    for seat <- seats do
      assert attendee.text_body =~ "/seat/#{seat.management_token}/reschedule"
      assert attendee.text_body =~ "/seat/#{seat.management_token}/cancel"
      assert organizer.text_body =~ "/dashboard/meetings?meeting=#{seat.meeting_id}"
    end

    assert ics_uids(ics(attendee).data) == Enum.map(seats, & &1.id)
  end

  test "dates are shown in the attendee's timezone and locale", %{host: host, today: today} do
    type = series_type(host)

    assert {:ok, %{meetings: booked}} =
             book(host, type, weekly(today, 2), %{
               user_timezone: "America/New_York",
               attendee_locale: "de"
             })

    drain_emails()
    {attendee, organizer} = sent_pair()

    for meeting <- booked do
      local = DateTime.shift_zone!(meeting.start_time, "America/New_York")
      month = Enum.at(@german_months, local.month - 1)

      assert attendee.text_body =~
               "#{local.day}. #{month} #{local.year} um #{Calendar.strftime(local, "%H:%M")}"
    end

    assert attendee.subject == "Ihre 2 Termine mit Grace Hopper sind gebucht"
    assert organizer.subject == "Ada Lovelace booked 2 sessions"
  end

  test "a failure to schedule the confirmation rolls the series back", %{
    host: host,
    today: today
  } do
    refuse_announcement_jobs!()
    type = series_type(host)

    assert {:error, :booking_failed} = book(host, type, weekly(today, 3))

    assert Repo.aggregate(SeriesSchema, :count) == 0
    assert Repo.aggregate(MeetingSchema, :count) == 0
  end

  test "the cancellation of several sessions is one email to each", %{
    host: host,
    today: today
  } do
    type = series_type(host)

    assert {:ok, %{series: series, meetings: [_first | rest]}} =
             book(host, type, weekly(today, 3))

    cancelled =
      for meeting <- rest do
        meeting |> Changeset.change(status: :cancelled) |> Repo.update!()
      end

    assert {:ok, :scheduled} =
             Notifications.schedule_series_cancellation(series, cancelled, :attendee)

    assert [job] =
             all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

    assert :ok = perform_job(EmailWorker, job.args)

    {attendee, organizer} = sent_pair()

    assert attendee.subject == "2 sessions cancelled"
    assert organizer.subject == "Ada Lovelace cancelled 2 sessions"
    assert attendee.text_body =~ "Session 2 of 3"
    assert attendee.text_body =~ "Session 3 of 3"
    refute attendee.text_body =~ "Session 1 of 3"

    data = ics(attendee).data
    assert ics_uids(data) == Enum.map(cancelled, & &1.calendar_uid)
    assert length(Regex.scan(~r/^STATUS:CANCELLED/m, data)) == 2
  end

  defp weekday(datetime), do: Calendar.strftime(datetime, "%A")

  # Refuses the series' announcement job at insert, as a failing queue
  # would, through a constraint Oban's changeset declares so that the insert
  # returns an error rather than raising. Rolled back with the test's
  # sandbox transaction.
  defp refuse_announcement_jobs! do
    Repo.query!("""
    CREATE FUNCTION test_refuse_series_job() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'series jobs refused' USING ERRCODE = 'check_violation',
        CONSTRAINT = 'priority_range';
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_refuse_series_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW WHEN (NEW.worker = 'Tymeslot.Workers.SeriesAnnouncementWorker')
    EXECUTE FUNCTION test_refuse_series_job()
    """)
  end
end
