defmodule Tymeslot.Meetings.AttendeeNotifications.ChangeEmailDeliveryTest do
  @moduledoc """
  Attendee change notifications carried all the way to a delivered email:

      Worker (or an immediate send) → EmailWorker job → template → Swoosh

  Only the Swoosh test adapter stands in for the outside world; the email
  service, templates and ICS generator run for real, so what is asserted is
  what an attendee would read.

  Two classes of event are pinned here that the rest of the suite does not
  reach: all-day events, which have dates and no instants, and events that
  are notified for the first time, whose previous state was never recorded.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications
  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  setup do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user, name: "Olive Organiser")
    integration = insert(:calendar_integration, user: user)

    %{user: user, integration: integration}
  end

  describe "an all-day event" do
    test "renaming it delivers an update that shows its days, not a clock time", %{
      integration: integration
    } do
      event =
        insert_all_day_event(integration,
          summary: "Team offsite",
          last_notified_state: all_day_baseline("Offsite", ~D[2026-10-12], ~D[2026-10-15])
        )

      email = run_update_to_delivery(event)

      assert email.to == [{"", "guest@example.com"}]
      assert email.text_body =~ "Time: All day, until October 14, 2026"
      assert email.text_body =~ "Title: Offsite → Team offsite"
      assert email.html_body =~ "All day, until October 14, 2026"
      assert email.html_body =~ "3 days"
      refute email.html_body =~ "TBD"

      ics = calendar_attachment(email)
      assert ics.data =~ "DTSTART;VALUE=DATE:20261012"
      assert ics.data =~ "DTEND;VALUE=DATE:20261015"
    end

    test "moving it to other days announces the date range it moved from and to", %{
      integration: integration
    } do
      event =
        insert_all_day_event(integration,
          summary: "Team offsite",
          last_notified_state: all_day_baseline("Team offsite", ~D[2026-10-05], ~D[2026-10-08])
        )

      email = run_update_to_delivery(event)

      assert email.text_body =~ "Time: October 5 – 7, 2026 → October 12 – 14, 2026"
      refute email.text_body =~ "Title:"
    end

    test "adding an attendee delivers an invitation that shows its days", %{
      integration: integration
    } do
      event = insert_all_day_event(integration, summary: "Team offsite")

      assert {:ok, :sent} =
               AttendeeNotifications.attendees_added(event, [%{email: "new@example.com"}])

      assert [job] = enqueued_jobs("send_calendar_invitation")
      assert :ok = perform_job(EmailWorker, job.args)

      assert_received {:email, email}
      assert email.to == [{"", "new@example.com"}]
      assert email.text_body =~ "Time: All day, until October 14, 2026"
      assert email.html_body =~ "3 days"

      ics = calendar_attachment(email)
      assert ics.data =~ "DTSTART;VALUE=DATE:20261012"
      assert ics.data =~ "DTEND;VALUE=DATE:20261015"
    end
  end

  describe "an event notified for the first time" do
    test "moving it announces its current time, not a title changed from nothing", %{
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 09:45:00.000000Z]
        )

      email = run_update_to_delivery(event, fn job -> assert job.args["first_notification"] end)

      assert email.text_body =~ "Current Details"
      assert email.text_body =~ "Time: 03 Nov 2026, 09:30 UTC"
      assert email.text_body =~ "Title: Standup"
      refute email.text_body =~ "What Changed"
      refute email.text_body =~ "→"

      assert email.html_body =~ "Current details"
      refute email.html_body =~ "What changed"
      refute email.html_body =~ "(none)"
    end

    test "is still delivered when its title, location and description are blank", %{
      integration: integration
    } do
      event =
        insert_timed_event(integration,
          summary: "",
          location: "",
          description: "",
          start_at: ~U[2026-11-04 14:00:00.000000Z],
          end_at: ~U[2026-11-04 15:00:00.000000Z]
        )

      email = run_update_to_delivery(event)

      assert email.text_body =~ "Time: 04 Nov 2026, 14:00 UTC"
      refute email.text_body =~ "Title:"
    end

    test "of an all-day event states its days", %{integration: integration} do
      event = insert_all_day_event(integration, summary: "Offsite")

      email = run_update_to_delivery(event)

      assert email.text_body =~ "Current Details"
      assert email.text_body =~ "Time: October 12 – 14, 2026"
    end
  end

  describe "a job enqueued before the first-notification flag existed" do
    setup %{user: user, integration: integration} do
      event =
        insert_timed_event(integration,
          summary: "Standup",
          start_at: ~U[2026-11-03 09:30:00.000000Z],
          end_at: ~U[2026-11-03 09:45:00.000000Z]
        )

      args = %{
        "action" => "send_event_update_notification",
        "user_id" => user.id,
        "event_uid" => event.uid,
        "integration_id" => integration.id,
        "attendee_emails" => ["guest@example.com"],
        "before_title" => "Daily sync",
        "before_location" => "",
        "before_description" => "",
        "before_start_at" => "2026-11-03T09:30:00Z",
        "before_end_at" => "2026-11-03T09:45:00Z",
        "method" => "request",
        "sequence" => 1
      }

      %{args: args}
    end

    test "still diffs its before values into a change list", %{args: args} do
      assert :ok = perform_job(EmailWorker, args)

      assert_received {:email, email}
      assert email.text_body =~ "What Changed"
      assert email.text_body =~ "Title: Daily sync → Standup"
      refute email.text_body =~ "Current Details"
    end

    test "still sends nothing when its before values match the event", %{args: args} do
      assert :ok = perform_job(EmailWorker, Map.put(args, "before_title", "Standup"))

      refute_received {:email, _email}
    end
  end

  # Runs the debounced Worker for an edited event, performs the email job it
  # enqueued with the job's own args, and returns the one delivered email.
  defp run_update_to_delivery(event, inspect_job \\ fn _job -> :ok end) do
    assert :ok =
             perform_job(Worker, %{
               "event_id" => event.id,
               "kind" => "provider_calendar_event",
               "action" => "update"
             })

    assert [job] = enqueued_jobs("send_event_update_notification")
    inspect_job.(job)
    assert :ok = perform_job(EmailWorker, job.args)

    assert_received {:email, email}
    refute_received {:email, _another}
    email
  end

  defp calendar_attachment(email) do
    assert [ics] = Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))
    ics
  end

  defp enqueued_jobs(action) do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["action"] == action))
  end

  defp insert_all_day_event(integration, attrs) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          all_day: true,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-15],
          start_at: nil,
          end_at: nil,
          location: "",
          description: "",
          attendees: [%{"email" => "guest@example.com"}],
          last_notified_state: %{}
        ],
        attrs
      )
    )
  end

  defp insert_timed_event(integration, attrs) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          location: "",
          description: "",
          attendees: [%{"email" => "guest@example.com"}],
          last_notified_state: %{}
        ],
        attrs
      )
    )
  end

  defp all_day_baseline(title, start_date, end_date) do
    LastNotifiedState.serialise(
      %{title: title, start_date: start_date, end_date: end_date, location: "", description: ""},
      [%{email: "guest@example.com"}]
    )
  end
end
