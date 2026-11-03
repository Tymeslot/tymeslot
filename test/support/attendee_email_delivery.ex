defmodule Tymeslot.Test.AttendeeEmailDelivery do
  @moduledoc """
  Carries an attendee notification through to the delivered email, for tests
  that run the notification worker, the email job, the template and the ICS
  generator for real with only the Swoosh test adapter standing in:

      Worker (or an immediate send) → EmailWorker job → template → Swoosh

  The calling test sets `:email_service_module` to the real email service and
  `:swoosh, :shared_test_process` to itself, so the emails arrive in its
  mailbox.
  """

  import ExUnit.Assertions
  import Tymeslot.Factory

  alias Oban.Testing
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  # Performs every enqueued email job of `action` with its own args and
  # returns the emails they delivered, one per job.
  @spec deliver_all(String.t()) :: [Swoosh.Email.t()]
  def deliver_all(action) do
    jobs = enqueued_jobs(action)
    assert jobs != []

    for job <- jobs do
      assert :ok = Testing.perform_job(EmailWorker, job.args, repo: Repo)
      assert_received {:email, email}
      email
    end
  end

  # Runs the debounced Worker for an edited event, performs the email job it
  # enqueued with the job's own args, and returns the one delivered email.
  @spec run_update_to_delivery(map(), (Oban.Job.t() -> term())) :: Swoosh.Email.t()
  def run_update_to_delivery(event, inspect_job \\ fn _job -> :ok end) do
    assert :ok =
             Testing.perform_job(
               Worker,
               %{
                 "event_id" => event.id,
                 "kind" => "provider_calendar_event",
                 "action" => "update"
               },
               repo: Repo
             )

    assert [job] = enqueued_jobs("send_event_update_notification")
    inspect_job.(job)
    assert :ok = Testing.perform_job(EmailWorker, job.args, repo: Repo)

    assert_received {:email, email}
    refute_received {:email, _another}
    email
  end

  @spec calendar_attachment(Swoosh.Email.t()) :: Swoosh.Attachment.t()
  def calendar_attachment(email) do
    assert [ics] = Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))
    ics
  end

  @spec enqueued_jobs(String.t()) :: [Oban.Job.t()]
  def enqueued_jobs(action) do
    Repo
    |> Testing.all_enqueued(worker: EmailWorker)
    |> Enum.filter(&(&1.args["action"] == action))
  end

  @spec insert_all_day_event(map(), keyword()) :: map()
  def insert_all_day_event(integration, attrs) do
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

  @spec insert_timed_event(map(), keyword()) :: map()
  def insert_timed_event(integration, attrs) do
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

  @spec all_day_baseline(String.t(), Date.t(), Date.t()) :: map()
  def all_day_baseline(title, start_date, end_date) do
    LastNotifiedState.serialise(
      %{title: title, start_date: start_date, end_date: end_date, location: "", description: ""},
      [%{email: "guest@example.com"}]
    )
  end
end
