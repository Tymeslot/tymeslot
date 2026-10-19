defmodule Tymeslot.Notifications.EmailHandlers do
  @moduledoc """
  Runs an email job's action through its handler, one of the
  `Tymeslot.Notifications.Email.*` modules, which hold the rules for each
  email: who receives it, what makes it stale, how a retry avoids a second
  send. `Tymeslot.Workers.EmailWorker` stays the thin Oban side: timeout,
  snoozes and the outcome it hands Oban. The action table is
  `Tymeslot.Emails.EmailActions`.
  """

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Notifications.Email.AuthEmails
  alias Tymeslot.Notifications.Email.EndChangeEmails
  alias Tymeslot.Notifications.Email.GroupMeetingEmails
  alias Tymeslot.Notifications.Email.GuestEmails
  alias Tymeslot.Notifications.Email.IntegrationEmails
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.PollEmails
  alias Tymeslot.Notifications.Email.RescheduleEmails
  alias Tymeslot.Notifications.Email.RescheduleRequestEmails
  alias Tymeslot.Notifications.Email.SeatJobs

  # The handlers that declare some of their discards an expected end of the
  # job. `AdminEmails` discards nothing of its own.
  @declaring_handlers [
    AuthEmails,
    EndChangeEmails,
    GroupMeetingEmails,
    GuestEmails,
    IntegrationEmails,
    MeetingEmails,
    PollEmails,
    RescheduleEmails,
    RescheduleRequestEmails,
    SeatJobs
  ]

  @doc """
  Whether `reason`, from a discard one of the handlers returned, is an
  expected end of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: Enum.any?(@declaring_handlers, & &1.expected_discard?(reason))

  @doc """
  Executes the specified email action with the given arguments.

  This is the primary entry point for the EmailWorker to process various types of
  email jobs, including confirmations, reminders, and authentication emails.

  Returns `:ok` on success, `{:error, reason}` for retriable failures, or
  `{:discard, reason}` for fatal errors that shouldn't be retried. Snoozing
  (an open mail circuit, a rate limit) is `EmailWorker`'s decision, made from
  the error reason.

  `job_id` is the id of the Oban job running the action, or `nil` for a job
  that was never persisted (which cannot be rescued, so needs no guard).
  """
  @spec execute_email_action(String.t(), %{String.t() => term()}, integer() | nil) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def execute_email_action(action, args, job_id \\ nil) do
    case EmailActions.handler(action) do
      {:ok, {module, fun}} -> apply(module, fun, [args])
      {:ok, {module, fun, :with_job_id}} -> apply(module, fun, [args, job_id])
      :error -> {:discard, "Unknown action: #{action}"}
    end
  end
end
