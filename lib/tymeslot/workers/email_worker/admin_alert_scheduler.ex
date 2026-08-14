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
  # stopped holding the dedup slot the moment it discarded — and since a discard
  # is itself what raises the next `oban_job_failure` alert, one email outage
  # produced an unbounded chain of alert jobs instead of a single deduplicated
  # one. The Pruner's `max_age` is a week in dev and production, comfortably
  # longer than this window, so terminal jobs are still present to match against.
  @dedup_states [
    :available,
    :scheduled,
    :executing,
    :retryable,
    :completed,
    :discarded,
    :cancelled
  ]

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
      "action" => "send_admin_alert",
      "recipient" => recipient,
      "category" => category,
      "severity" => to_string(severity),
      "message" => message,
      "metadata" => serialize_metadata(metadata),
      "alert_hash" => compute_alert_hash(category, dedup_key)
    }
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

  defp compute_alert_hash(category, message) do
    "#{category}:#{message}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16()
  end

  defp serialize_metadata(metadata) when is_map(metadata) do
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
