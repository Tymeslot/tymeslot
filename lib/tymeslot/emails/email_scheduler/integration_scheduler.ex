defmodule Tymeslot.Emails.EmailScheduler.IntegrationScheduler do
  @moduledoc "Schedules integration health and admin alert emails via Oban."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  @type entity_with_id :: %{required(:id) => pos_integer(), optional(atom()) => term()}

  @doc """
  Schedules an integration unhealthy notification email with medium priority.

  Uses a 30-day uniqueness window per user + integration + type so that a
  re-occurring flap does not immediately re-send after a cooldown expires.
  The ResponseHandler also honours the `notification_sent_at` the email worker
  stamps after delivery, for the same reason; the Oban uniqueness is a
  belt-and-suspenders safeguard.
  """
  @spec schedule_integration_unhealthy_notification(
          entity_with_id(),
          entity_with_id(),
          atom() | String.t()
        ) :: :ok | {:error, term()}
  def schedule_integration_unhealthy_notification(user, integration, type) do
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
    |> Helpers.insert(user_id: user.id, integration_id: integration.id, type: type)
    |> Helpers.ok()
  end

  @doc """
  Schedules a "reconnect required" notification email.

  Sent when an integration is flagged `needs_reauth`. The 30-day uniqueness
  window matches the unhealthy notification's: an integration that is flagged,
  reconnected and flagged again inside a month is a user already aware of the
  problem, and a second email would not tell them anything new.
  """
  @spec schedule_integration_reauth_notification(
          entity_with_id(),
          entity_with_id(),
          atom() | String.t()
        ) :: :ok | {:error, term()}
  def schedule_integration_reauth_notification(user, integration, type) do
    %{
      "action" => "send_integration_reauth_notification",
      "user_id" => user.id,
      "integration_id" => integration.id,
      "integration_type" => to_string(type)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 2,
      unique: [
        period: 30 * 24 * 60 * 60,
        fields: [:args, :queue],
        keys: [:action, :user_id, :integration_id, :integration_type]
      ]
    )
    |> Helpers.insert(user_id: user.id, integration_id: integration.id, type: type)
    |> Helpers.ok()
  end

  @doc """
  Schedules the email telling an owner that the calendar server no longer has
  `calendar_names`, so Tymeslot has stopped using them.

  Carries no uniqueness of its own: it is inserted in the transaction that
  deselects those calendars, which is the guarantee that one deselection
  sends one email (a retried sync finds them already deselected).
  """
  @spec schedule_calendars_removed_notification(pos_integer(), pos_integer(), [String.t()]) ::
          :ok | {:error, term()}
  def schedule_calendars_removed_notification(
        user_id,
        integration_id,
        [_first | _rest] = calendar_names
      ) do
    %{
      "action" => "send_calendars_removed_notification",
      "user_id" => user_id,
      "integration_id" => integration_id,
      "calendar_names" => calendar_names
    }
    |> EmailWorker.new(queue: :emails, priority: 2)
    |> Helpers.insert(
      user_id: user_id,
      integration_id: integration_id,
      count: length(calendar_names)
    )
    |> Helpers.ok()
  end

  @doc """
  Schedules the email telling an owner that their video provider refuses to
  create rooms for an integration, with the refusal's `code`.

  Carries no uniqueness of its own: `Tymeslot.Integrations.Video.RoomCreationError`
  claims each code once per integration before calling this, inside the same
  transaction, which is the guarantee that the owner is emailed about it once.
  """
  @spec schedule_video_room_creation_error_notification(pos_integer(), pos_integer(), atom()) ::
          :ok | {:error, term()}
  def schedule_video_room_creation_error_notification(user_id, integration_id, code) do
    %{
      "action" => "send_video_room_creation_error_notification",
      "user_id" => user_id,
      "integration_id" => integration_id,
      "error_code" => Atom.to_string(code)
    }
    |> EmailWorker.new(queue: :emails, priority: 2)
    |> Helpers.insert(user_id: user_id, integration_id: integration_id, code: code)
    |> Helpers.ok()
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
        ) :: :ok | {:error, term()}
  def schedule_integration_paused_notification(user, integration, type, cutoff_days) do
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
    |> Helpers.insert(user_id: user.id, integration_id: integration.id, type: type)
    |> Helpers.ok()
  end

  @doc """
  Schedules an administrative alert email.

  Delegates to `Tymeslot.Workers.EmailWorker.AdminAlertScheduler.schedule/6`,
  which handles dedup via Oban's uniqueness constraint (24-hour window keyed on
  recipient + category + dedup hash; pass `dedup_key:` in `opts` to override
  the default message-based hash).
  """
  @spec schedule_admin_alert(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map(),
          opts :: [dedup_key: String.t()]
        ) :: :ok | {:error, term()}
  defdelegate schedule_admin_alert(recipient, category, severity, message, metadata, opts \\ []),
    to: Tymeslot.Workers.EmailWorker.AdminAlertScheduler,
    as: :schedule

  @doc """
  Schedules the daily digest email of info-severity admin alerts.

  Delegates to `Tymeslot.Workers.EmailWorker.AdminAlertScheduler.schedule_digest/2`.
  """
  @spec schedule_admin_alert_digest(recipient :: String.t(), digest :: map()) ::
          :ok | {:error, term()}
  defdelegate schedule_admin_alert_digest(recipient, digest),
    to: Tymeslot.Workers.EmailWorker.AdminAlertScheduler,
    as: :schedule_digest
end
