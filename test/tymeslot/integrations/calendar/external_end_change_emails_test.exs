defmodule Tymeslot.Integrations.Calendar.ExternalEndChangeEmailsTest do
  @moduledoc """
  A host who lengthens or shortens a booked meeting in their own calendar
  has the booking follow (see `ExternalEndChangeTest`); this covers who is
  told. The booker, or every participant of a group meeting, and every guest
  get the new end with an updated calendar entry, then the host is told who
  was notified. A change that did not land, or that the host took back
  before the notice went out, tells nobody, and several quick changes tell
  everyone once.

  The Google API client is mocked at its behaviour; the sync, the meetings
  table, the email job and the real email templates run as they do in
  production, delivered to the test process.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :emails
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  @event_id "booked-evt-1"

  setup do
    TestMocks.setup_all_mocks()
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    profile = insert(:profile, timezone: "Etc/UTC")

    integration =
      insert(:calendar_integration,
        provider: "google",
        google_sync_token: "token",
        user: profile.user
      )

    date = Date.add(Date.utc_today(), 10)
    start_time = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

    meeting =
      insert(:meeting,
        organizer_user_id: profile.user_id,
        calendar_integration_id: integration.id,
        provider_event_id: @event_id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30,
        attendee_timezone: "Etc/UTC"
      )

    %{integration: integration, meeting: meeting, date: date}
  end

  describe "a meeting lengthened in Google" do
    test "emails the booker and their guest the new end, then tells the host", ctx do
      {:ok, _guests} = Guests.create_for_meeting(ctx.meeting.id, ["guest@example.com"])

      sync(ctx, ~T[11:30:00])
      assert [job] = all_enqueued(worker: EmailWorker)

      assert job.args == %{
               "action" => "send_end_change_emails",
               "meeting_id" => ctx.meeting.id,
               "start_time" => DateTime.to_iso8601(ctx.meeting.start_time)
             }

      assert :ok = perform_job(EmailWorker, job.args)

      booker = received_for(ctx.meeting.attendee_email)
      assert booker.subject =~ "New end time"
      assert booker.text_body =~ "now ends at 11:30 AM UTC instead of 10:30 AM UTC"

      # The entry the booker's calendar holds is replaced, not duplicated:
      # same UID, a higher SEQUENCE than the invitation's 0.
      ics = ics(booker)
      assert ics =~ "UID:#{ctx.meeting.calendar_uid}"
      assert ics =~ "SEQUENCE:1"

      assert ics =~
               "DTEND:#{Calendar.strftime(DateTime.new!(ctx.date, ~T[11:30:00], "Etc/UTC"), "%Y%m%dT%H%M%SZ")}"

      guest = received_for("guest@example.com")
      assert guest.text_body =~ "now ends at 11:30 AM UTC instead of 10:30 AM UTC"

      host = received_for(ctx.meeting.organizer_email)
      assert host.subject =~ "now ends at 11:30 AM"
      assert host.text_body =~ "We emailed Test Attendee the new end time"
      assert host.text_body =~ "Their guest was emailed too."
    end

    test "several quick changes send one notice, with the end the host settled on", ctx do
      sync(ctx, ~T[11:30:00])
      sync(ctx, ~T[12:00:00])

      assert [job] = all_enqueued(worker: EmailWorker)

      assert :ok = perform_job(EmailWorker, job.args)

      booker = received_for(ctx.meeting.attendee_email)
      assert booker.text_body =~ "now ends at 12:00 PM UTC instead of 10:30 AM UTC"
      assert ics(booker) =~ "SEQUENCE:2"

      received_for(ctx.meeting.organizer_email)
      refute_received {:email, _another}
    end

    test "an end moved back before the notice went out tells nobody", ctx do
      sync(ctx, ~T[11:30:00])
      sync(ctx, ~T[10:30:00])

      assert [job] = all_enqueued(worker: EmailWorker)
      assert {:discard, _reason} = perform_job(EmailWorker, job.args)
      refute_received {:email, _any}
    end
  end

  describe "in the recipients' own languages" do
    test "the booker reads it in theirs and the host in theirs", ctx do
      meeting = ctx.meeting |> Changeset.change(attendee_locale: "de") |> Repo.update!()

      Repo.update_all(
        from(u in UserSchema, where: u.id == ^meeting.organizer_user_id),
        set: [locale: "fr"]
      )

      sync(ctx, ~T[11:30:00])
      assert [job] = all_enqueued(worker: EmailWorker)
      assert :ok = perform_job(EmailWorker, job.args)

      booker = received_for(meeting.attendee_email)
      assert booker.subject =~ "Neue Endzeit"
      assert booker.text_body =~ "unser Termin endet jetzt um"

      host = received_for(meeting.organizer_email)
      assert host.subject =~ "se termine désormais à"
      assert host.text_body =~ "Nous avons envoyé la nouvelle heure de fin à Test Attendee"
    end
  end

  describe "a group meeting lengthened in Google" do
    test "emails every participant, each on their own calendar entry, then the host", ctx do
      meeting =
        ctx.meeting
        |> Changeset.change(capacity: 4, attendee_name: nil, attendee_email: nil)
        |> Repo.update!()

      first = insert(:participant, meeting: meeting, timezone: "Etc/UTC")
      second = insert(:participant, meeting: meeting, timezone: "Etc/UTC")

      sync(ctx, ~T[11:30:00])
      assert [job] = all_enqueued(worker: EmailWorker)
      assert :ok = perform_job(EmailWorker, job.args)

      for participant <- [first, second] do
        email = received_for(participant.email)
        assert email.text_body =~ "now ends at 11:30 AM UTC instead of 10:30 AM UTC"
        assert ics(email) =~ "UID:#{participant.id}"
        assert ics(email) =~ "SEQUENCE:#{participant.ical_sequence + 1}"
      end

      host = received_for(meeting.organizer_email)
      assert host.text_body =~ "We emailed 2 participants the new end time"
    end
  end

  describe "who is not told" do
    test "nobody, when the change lost its race with a cancellation", ctx do
      read = ctx.meeting
      read |> Changeset.change(status: "cancelled") |> Repo.update!()

      assert :ok = Meetings.apply_external_end_change(read, DateTime.add(read.end_time, 1, :hour))

      refute_enqueued(worker: EmailWorker)
    end

    test "not the host, when no attendee could be reached", ctx do
      Application.put_env(:tymeslot, :email_service_module, EmailServiceMock)

      expect(EmailServiceMock, :send_end_change_to_attendee, fn _email, _details ->
        {:error, {:recipient_rejected, "550 no such user"}}
      end)

      expect(EmailServiceMock, :send_end_change_to_organizer, 0, fn _meeting, _email, _notice ->
        {:ok, :sent}
      end)

      sync(ctx, ~T[11:30:00])
      assert [job] = all_enqueued(worker: EmailWorker)
      assert :ok = perform_job(EmailWorker, job.args)
    end
  end

  defp sync(ctx, end_time) do
    end_at = DateTime.new!(ctx.date, end_time, "Etc/UTC")

    event = %{
      "id" => @event_id,
      "iCalUID" => @event_id,
      "status" => "confirmed",
      "summary" => "Booked meeting",
      "start" => %{"dateTime" => DateTime.to_iso8601(ctx.meeting.start_time)},
      "end" => %{"dateTime" => DateTime.to_iso8601(end_at)}
    }

    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [event], next_sync_token: "token-2"}}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{
               "calendar_integration_id" => ctx.integration.id
             })
  end

  defp received_for(address) do
    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    email
  end

  defp ics(%Swoosh.Email{attachments: attachments}) do
    assert [%{data: data}] = Enum.filter(attachments, &String.ends_with?(&1.filename, ".ics"))
    data
  end
end
