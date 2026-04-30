defmodule Tymeslot.Emails.EmailScheduler.IntegrationScheduler do
  @moduledoc "Schedules integration health and admin alert emails via Oban."

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  require Logger

  @type entity_with_id :: %{required(:id) => pos_integer(), optional(atom()) => term()}

  @doc """
  Schedules an integration unhealthy notification email with medium priority.

  Uses a 30-day uniqueness window per user + integration + type so that a
  re-occurring flap does not immediately re-send after a cooldown expires.
  The ResponseHandler also tracks `notification_sent_at` in the DB for the same
  reason; the Oban uniqueness is a belt-and-suspenders safeguard.
  """
  @spec schedule_integration_unhealthy_notification(
          entity_with_id(),
          entity_with_id(),
          atom() | String.t()
        ) :: :ok | {:error, String.t()}
  def schedule_integration_unhealthy_notification(user, integration, type) do
    result =
      %{
        "action" => "send_integration_unhealthy_notification",
        "user_id" => user.id,
        "integration_id" => integration.id,
        "integration_type" => to_string(type)
      }
      |> EmailWorker.new(
        queue: :emails,
        priority: 2,
        unique: [
          # 30-day uniqueness to match the notification cooldown
          period: 30 * 24 * 60 * 60,
          fields: [:args, :queue],
          keys: [:action, :user_id, :integration_id, :integration_type]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Integration unhealthy notification job scheduled",
          user_id: user.id,
          integration_id: integration.id,
          type: type
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Integration unhealthy notification job already exists, skipping duplicate",
          user_id: user.id,
          integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule integration unhealthy notification",
          user_id: user.id,
          integration_id: integration.id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules an integration paused notification email.

  Sent once when the auto-pause worker deactivates an integration after the
  configured unhealthy cutoff period. The 90-day uniqueness window is
  belt-and-suspenders against an integration that the user reactivates and
  re-pauses within the same window — that's an extreme edge and one extra
  notification is preferable to silence.

  `cutoff_days` is the actual configured value (`:auto_pause_cutoff_days`)
  and is stored in the job args so the email template can render the correct
  threshold rather than a hard-coded number.
  """
  @spec schedule_integration_paused_notification(
          entity_with_id(),
          entity_with_id(),
          atom() | String.t(),
          pos_integer()
        ) :: :ok | {:error, String.t()}
  def schedule_integration_paused_notification(user, integration, type, cutoff_days) do
    result =
      %{
        "action" => "send_integration_paused_notification",
        "user_id" => user.id,
        "integration_id" => integration.id,
        "integration_type" => to_string(type),
        "cutoff_days" => cutoff_days
      }
      |> EmailWorker.new(
        queue: :emails,
        priority: 2,
        unique: [
          period: 90 * 24 * 60 * 60,
          fields: [:args, :queue],
          keys: [:action, :user_id, :integration_id, :integration_type]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Integration paused notification job scheduled",
          user_id: user.id,
          integration_id: integration.id,
          type: type
        )

        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Integration paused notification job already exists, skipping duplicate",
          user_id: user.id,
          integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule integration paused notification",
          user_id: user.id,
          integration_id: integration.id,
          error: Helpers.format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

  @doc """
  Schedules an administrative alert email.

  Delegates to `Tymeslot.Workers.EmailWorker.AdminAlertScheduler.schedule/5`,
  which handles dedup via Oban's uniqueness constraint (24-hour window keyed on
  recipient + category + message hash).
  """
  @spec schedule_admin_alert(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: :ok | {:error, String.t()}
  defdelegate schedule_admin_alert(recipient, category, severity, message, metadata),
    to: Tymeslot.Workers.EmailWorker.AdminAlertScheduler,
    as: :schedule
end
