defmodule Tymeslot.Workers.MeetingNotificationJob do
  @moduledoc """
  What the per-integration delivery workers (webhooks, Telegram, Slack) share:
  scheduling a delivery about a meeting event, loading the meeting it
  describes, gating it on the organiser's automations access, the retry
  schedule of the chat channels, and when a failure counts against an
  integration.

  The workers keep only what is theirs: the API call, the message, and how
  the provider's errors are classified.
  """

  alias Tymeslot.Features
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.SeatView

  # Only a delivery still waiting to run absorbs a duplicate. One that has run
  # (or is running) must never swallow a later event of the same type, such
  # as a second reschedule minutes after the first, so the window is
  # unbounded and the states, not a period, decide what counts.
  @pending_states [:available, :scheduled, :retryable]

  # Integration ids of different channels come from separate sequences and
  # routinely coincide, so `:worker` has to stay in the comparison: on args
  # alone two channels would share one uniqueness namespace.
  @unique_fields [:args, :worker]

  # Seconds after each failed attempt: 1, 2, 4, 8, then 16.
  @chat_backoff_cap 16

  @type feature_gate ::
          :ok
          | {:revoked, Features.access_error()}
          | {:discard, :feature_disabled}
          | {:error, :feature_access_checker_failed}

  @doc """
  Inserts a `worker` job for `args` (string keys, as stored) about one
  meeting event, as `schedule/5` is called by each channel worker:

    * `participant_id` names the seat of a group meeting the event is about,
      or is `nil` for a solo meeting. It is always written into the args and
      always part of the uniqueness key, so a seat's delivery and the
      meeting's own can never be taken for duplicates of each other.
    * `unique_keys` names the other args that identify one delivery.
    * `opts`: `:queue` (required) and `:priority` (default 2).

  A conflict with a delivery still waiting to run answers `:ok`, like a
  fresh insert; Oban reports both as `{:ok, job}`.
  """
  @spec schedule(module(), map(), binary() | nil, [atom()], keyword()) :: :ok | {:error, term()}
  def schedule(worker, args, participant_id, unique_keys, opts) do
    job =
      worker.new(Map.put(args, "participant_id", participant_id),
        queue: Keyword.fetch!(opts, :queue),
        priority: Keyword.get(opts, :priority, 2),
        unique: [
          period: :infinity,
          states: @pending_states,
          fields: @unique_fields,
          keys: unique_keys ++ [:participant_id]
        ]
      )

    case Oban.insert(job) do
      {:ok, %Oban.Job{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads the meeting a delivery describes. A seat's delivery (`participant_id`
  set) describes that seat's booking, cancelled or not: a group meeting row
  has no attendee of its own.
  """
  @spec load_meeting(binary(), binary() | nil) ::
          {:ok, Meetings.MeetingSchema.t()} | {:error, term()}
  def load_meeting(meeting_id, nil), do: Meetings.get_meeting(meeting_id)

  def load_meeting(meeting_id, participant_id) do
    with {:ok, meeting} <- Meetings.get_meeting(meeting_id) do
      SeatView.load(meeting, participant_id, nil)
    end
  end

  @doc """
  Whether the organiser may still receive automations, normalised to what a
  delivery does about it:

    * `:ok`: deliver.
    * `{:revoked, reason}`: the plan no longer covers automations; the job
      is dropped and the integration left as it is, so it resumes by itself
      once the plan covers automations again.
    * `{:discard, :feature_disabled}`: the instance has automations switched
      off; the job is dropped but the integration left as the user set it,
      since only the operator can switch the feature back on.
    * `{:error, :feature_access_checker_failed}`: the check itself failed;
      the job retries.
  """
  @spec feature_gate(integer()) :: feature_gate()
  def feature_gate(user_id) do
    case Features.check_access(user_id, :automations_allowed) do
      :ok -> :ok
      {:error, :feature_disabled} -> {:discard, :feature_disabled}
      {:error, :feature_access_checker_failed} = error -> error
      {:error, reason} -> {:revoked, reason}
    end
  end

  @doc "The chat channels' retry schedule: doubling from one second, capped at 16."
  @spec chat_backoff(Oban.Job.t()) :: pos_integer()
  def chat_backoff(%Oban.Job{attempt: attempt}),
    do: min(round(:math.pow(2, attempt - 1)), @chat_backoff_cap)

  @doc """
  Whether this execution is the job's last real attempt, the one on which a
  delivery failure is counted against the integration (once per job).

  A snooze costs no attempt (the engine rolls `attempt` back and keeps
  `max_attempts`), so this holds on the genuine last attempt however many
  snoozes came before it.
  """
  @spec final_attempt?(Oban.Job.t()) :: boolean()
  def final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}),
    do: attempt >= max_attempts
end
