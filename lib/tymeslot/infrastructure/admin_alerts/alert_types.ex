defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypes do
  @moduledoc """
  Central registry of admin alert types.

  Each of Core's alert types is defined once in `@registry` with its category
  and severity. `format_message/2` and `dedup_key/2` delegate to the sibling
  modules that hold each type's message and deduplication key.

  To add a new alert type to Core:
  1. Add an entry to `@registry`
  2. Add a `format_message/2` clause in `alert_types/messages.ex`
  3. If the message embeds per-occurrence detail, give the type its own key in
     `alert_types/dedup_key.ex` (a `@keyed_on` entry, or a `dedup_key/2` clause)

  A deployment that raises alert types of its own registers them through an
  `AlertTypeProvider` listed under `config :tymeslot,
  :admin_alert_type_providers`. Every function here answers for those types
  too, so the notifier formats and deduplicates every alert the same way.
  """

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes.{DedupKey, Messages}

  @registry %{
    unhandled_webhook: %{category: "Webhook", severity: :warning},
    refund_processed: %{category: "Payment", severity: :info},
    unlinked_refund: %{category: "Payment", severity: :error},
    dispute_created: %{category: "Dispute", severity: :error},
    dispute_lost: %{category: "Dispute", severity: :error},
    calendar_sync_error: %{category: "Calendar", severity: :error},
    invalid_calendar_event: %{category: "Calendar", severity: :warning},
    integration_health_failure: %{category: "System", severity: :error},
    integration_health_recovery: %{category: "System", severity: :info},
    oban_queue_stuck: %{category: "Queue", severity: :error},
    oban_jobs_accumulating: %{category: "Queue", severity: :warning},
    oban_jobs_force_discarded: %{category: "Queue", severity: :error},
    circuit_breaker_open: %{category: "System", severity: :warning},
    database_pool_pressure: %{category: "System", severity: :warning},
    stripe_webhook_secret_missing: %{category: "Payment", severity: :error},
    new_error: %{category: "Errors", severity: :error},
    error_regression: %{category: "Errors", severity: :error},
    refund_failed: %{category: "Payment", severity: :error},
    refund_stuck: %{category: "Payment", severity: :error},
    refund_failure_reversed: %{category: "Payment", severity: :warning},
    refund_duplicated: %{category: "Payment", severity: :error},
    late_payment_refund_failed: %{category: "Payment", severity: :error},
    connect_revocation_failed: %{category: "Payment", severity: :error},
    connect_event_unmatched: %{category: "Payment", severity: :error},
    account_deletion_stalled: %{category: "Account", severity: :error},
    account_deletion_held_last_admin: %{category: "Account", severity: :warning},
    analytics_tracking_anomaly: %{category: "Analytics", severity: :warning},
    recipient_email_rejected: %{category: "Email", severity: :info},
    configured_email_exhausted: %{category: "Email", severity: :error},
    user_registered_hook_failed: %{category: "System", severity: :error},
    group_meeting_release_failed: %{category: "Booking", severity: :error},
    upload_delete_failed: %{category: "System", severity: :warning},
    account_files_delete_failed: %{category: "Account", severity: :error}
  }

  @doc """
  Returns every registered type, Core's and each provider's, with its category
  and severity.
  """
  @spec registered_types() :: AlertTypeProvider.registry()
  def registered_types do
    Enum.reduce(providers(), @registry, &Map.merge(&1.registered_types(), &2))
  end

  @doc "Looks up category and severity for the given alert type. Returns nil for unknown types."
  @spec get(atom()) :: %{category: String.t(), severity: AlertTypeProvider.severity()} | nil
  def get(type), do: Map.get(registered_types(), type)

  @doc "See `DedupKey.dedup_key/2`; a provider's type is keyed by its provider."
  @spec dedup_key(atom(), map()) :: String.t()
  def dedup_key(type, metadata) do
    case provider_for(type) do
      nil -> DedupKey.dedup_key(type, metadata)
      provider -> provider.dedup_key(type, metadata)
    end
  end

  @doc "See `Messages.format_message/2`; a provider's type is formatted by its provider."
  @spec format_message(atom(), map()) :: String.t()
  def format_message(type, metadata) do
    case provider_for(type) do
      nil -> Messages.format_message(type, metadata)
      provider -> provider.format_message(type, metadata)
    end
  end

  @doc """
  The reason as `AdminAlerts.report/2` flattens it into the metadata: the
  normalised message, falling back to the bare code. For a provider's messages
  and keys, so they read a reason the way Core's do.
  """
  @spec reason_text(map()) :: term()
  defdelegate reason_text(metadata), to: Messages

  @doc """
  Raises unless every configured provider implements `AlertTypeProvider` and
  registers only types that neither Core nor an earlier provider registers.
  A clash would leave one definition silently shadowing the other.
  """
  @spec validate_providers!() :: :ok
  def validate_providers! do
    _registered =
      Enum.reduce(providers(), Map.keys(@registry), fn provider, taken ->
        unless provider?(provider) do
          raise ArgumentError,
                ":admin_alert_type_providers entry #{inspect(provider)} does not implement " <>
                  inspect(AlertTypeProvider)
        end

        types = Map.keys(provider.registered_types())

        case Enum.filter(types, &(&1 in taken)) do
          [] ->
            types ++ taken

          clashes ->
            raise ArgumentError,
                  ":admin_alert_type_providers entry #{inspect(provider)} registers " <>
                    "#{inspect(Enum.sort(clashes))}, already registered by Core or an earlier provider"
        end
      end)

    :ok
  end

  # Read at call time, not with `compile_env`, so that tests can swap the
  # providers with `with_config`.
  defp providers, do: Application.get_env(:tymeslot, :admin_alert_type_providers, [])

  defp provider_for(type) when is_map_key(@registry, type), do: nil

  defp provider_for(type) do
    Enum.find(providers(), &is_map_key(&1.registered_types(), type))
  end

  defp provider?(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(AlertTypeProvider.behaviour_info(:callbacks), fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
  end
end
