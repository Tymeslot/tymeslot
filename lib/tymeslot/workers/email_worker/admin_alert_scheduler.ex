defmodule Tymeslot.Workers.EmailWorker.AdminAlertScheduler do
  @moduledoc """
  Helpers for scheduling admin alert emails through `Tymeslot.Workers.EmailWorker`.

  Lives in its own module so the email worker stays focused on dispatch and the
  admin alert dedup/serialisation rules can be tested in isolation.
  """

  require Logger

  alias Tymeslot.Workers.EmailWorker

  # Dedup window for identical admin alerts (24 hours, in seconds).
  # A recurring issue produces at most one email per day for the same content.
  @dedup_period_seconds 86_400

  # The terminal states are included deliberately. Oban's default omits
  # `:discarded` and `:cancelled`, so an alert job that exhausted its retries
  # stopped holding the dedup slot the moment it discarded, so the next
  # identical alert enqueued a fresh job at once. When the alert jobs' own
  # failures raised further alerts, one email outage produced an unbounded
  # chain of alert jobs instead of a single deduplicated one. The Pruner's
  # `max_age` is a week in dev and production, comfortably longer than this
  # window, so terminal jobs are still present to match against.
  @dedup_states [
    :available,
    :scheduled,
    :executing,
    :retryable,
    :completed,
    :discarded,
    :cancelled
  ]

  # Holding the slot through a discard is only safe because an alert job
  # outlasts a realistic mail outage: the worker-wide policy spends its five
  # attempts in about half a minute, which lost an alert raised during an SMTP
  # outage, and every repeat of it for the rest of the day. 20 attempts on a
  # backoff doubling from a minute up to an hour span about 14 hours, and stay
  # inside the dedup window, so the job holds the slot for its whole life and
  # a repeat raised while it retries is still deduplicated. A rejected
  # recipient still discards at once and an open breaker still snoozes (a
  # snooze costs no attempt), exactly as for every other email.
  @max_attempts 20
  @backoff_base_seconds 60
  @backoff_cap_seconds 3_600

  @alert_action "send_admin_alert"
  @digest_action "send_admin_alert_digest"

  @doc """
  Builds the args map for an admin alert job, including the SHA-256 dedup hash.

  The hash is derived from the category plus the `:dedup_key` option when
  given, falling back to the message. Callers whose messages embed
  per-occurrence detail should pass a stable `:dedup_key` so repeat alerts
  collapse within the dedup window instead of each hashing differently.
  """
  @spec build_args(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map(),
          opts :: [dedup_key: String.t()]
        ) :: map()
  def build_args(recipient, category, severity, message, metadata, opts \\ []) do
    dedup_key = Keyword.get(opts, :dedup_key) || message

    %{
      "action" => @alert_action,
      "recipient" => recipient,
      "category" => category,
      "severity" => to_string(severity),
      "message" => message,
      "metadata" => serialize_metadata(metadata),
      "alert_hash" => alert_hash(category, dedup_key)
    }
  end

  @doc """
  Seconds to wait before retrying an admin alert job after its `attempt`th
  failure. `Tymeslot.Workers.EmailWorker.backoff/1` delegates here for the
  admin alert action only.
  """
  @spec backoff(Oban.Job.t()) :: pos_integer()
  def backoff(%Oban.Job{attempt: attempt}) do
    min(@backoff_base_seconds * Integer.pow(2, attempt - 1), @backoff_cap_seconds)
  end

  @doc """
  Inserts an admin alert job into Oban with a 24-hour dedup window.

  Identical alerts (same recipient + category + dedup hash) within the
  window are silently dropped via Oban's uniqueness constraint, so a
  persistent issue produces at most one email per day for the same content.
  """
  @spec schedule(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map(),
          opts :: [dedup_key: String.t()]
        ) :: :ok | {:error, String.t()}
  def schedule(recipient, category, severity, message, metadata, opts \\ []) do
    args = build_args(recipient, category, severity, message, metadata, opts)

    result =
      args
      |> EmailWorker.new(
        queue: :emails,
        priority: 3,
        max_attempts: @max_attempts,
        unique: [
          period: @dedup_period_seconds,
          fields: [:args, :queue],
          keys: [:action, :recipient, :alert_hash],
          states: @dedup_states
        ]
      )
      |> Oban.insert()

    handle_insert_result(result, category, args["alert_hash"])
  end

  # A uniqueness conflict comes back as `{:ok, job}` carrying `conflict?: true`,
  # not as an insert error — Oban returns the job already holding the slot.
  # Matching it here keeps the logs honest: without this clause every
  # deduplicated alert still logged "scheduled", so a worker failing on a loop
  # looked like it was emailing an operator each cycle when it was not.
  defp handle_insert_result({:ok, %Oban.Job{conflict?: true}}, category, alert_hash) do
    Logger.debug("Admin alert email already pending, deduplicated",
      category: category,
      alert_hash: alert_hash
    )

    :ok
  end

  defp handle_insert_result({:ok, _job}, category, _hash) do
    Logger.info("Admin alert email scheduled", category: category)
    :ok
  end

  defp handle_insert_result(
         {:error, %Ecto.Changeset{errors: [unique: _details]}},
         category,
         alert_hash
       ) do
    Logger.debug("Admin alert email already pending, deduplicated",
      category: category,
      alert_hash: alert_hash
    )

    :ok
  end

  defp handle_insert_result({:error, reason}, category, _hash) do
    Logger.error("Failed to schedule admin alert email",
      category: category,
      error: inspect(reason)
    )

    {:error, "Failed to schedule job"}
  end

  @doc """
  Inserts the daily digest of info-severity admin alerts as one email job.

  No uniqueness: the digest's entries are deleted as it is handed off, so a
  second digest can only carry alerts the first did not. It retries on the
  same long schedule as an alert email.
  """
  @spec schedule_digest(recipient :: String.t(), digest :: map()) :: :ok | {:error, term()}
  def schedule_digest(recipient, digest) do
    result =
      digest
      |> Map.merge(%{"action" => @digest_action, "recipient" => recipient})
      |> EmailWorker.new(queue: :emails, priority: 3, max_attempts: @max_attempts)
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule admin alert digest email", error: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  The email worker actions that deliver admin alerts: an alert email and the
  daily digest. They share the long retry schedule, and a failure of either
  must not raise an alert that would travel the same broken path.
  """
  @spec actions() :: [String.t()]
  def actions, do: [@alert_action, @digest_action]

  @doc """
  The SHA-256 dedup hash of an alert: its category plus its dedup key. Keys
  both the alert email's uniqueness and the digest entry an info alert
  collapses into.
  """
  @spec alert_hash(String.t(), String.t()) :: String.t()
  def alert_hash(category, dedup_key) do
    "#{category}:#{dedup_key}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
  end

  @doc """
  Converts alert metadata to JSON-safe values with string keys, as stored in
  job args and digest entries. Anything without a JSON form is `inspect`ed.
  """
  @spec serialize_metadata(map()) :: map()
  def serialize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(v) when is_binary(v), do: v
  defp serialize_value(v) when is_boolean(v), do: v
  defp serialize_value(v) when is_atom(v), do: to_string(v)
  defp serialize_value(v) when is_number(v), do: v
  defp serialize_value(v) when is_list(v), do: Enum.map(v, &serialize_value/1)
  defp serialize_value(v) when is_map(v), do: serialize_metadata(v)
  defp serialize_value(v), do: inspect(v)
end
