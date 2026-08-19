defmodule Tymeslot.Features do
  @moduledoc """
  Feature access checks for paid and gated functionality.

  Core uses a configurable checker module. SaaS can override this via config.
  """

  require Logger

  @type access_error ::
          :insufficient_plan
          | :feature_disabled
          | :pro_required
          | :stripe_required
          | :feature_access_checker_failed

  @spec check_access(integer(), atom()) :: :ok | {:error, access_error()}
  def check_access(user_id, feature) when is_integer(user_id) and is_atom(feature) do
    module =
      Application.get_env(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

    # Use configured checker (e.g., SaaS subscription checker)
    try do
      case module.check_access(user_id, feature) do
        :ok ->
          :ok

        {:error, :insufficient_plan} = error ->
          error

        {:error, :feature_disabled} = error ->
          error

        {:error, :pro_required} = error ->
          error

        {:error, :stripe_required} = error ->
          error

        {:error, reason} ->
          Logger.warning("Feature access checker returned error",
            user_id: user_id,
            feature: feature,
            reason: inspect(reason)
          )

          {:error, :feature_access_checker_failed}

        other ->
          Logger.warning("Feature access checker returned unexpected value",
            user_id: user_id,
            feature: feature,
            result: inspect(other)
          )

          {:error, :feature_access_checker_failed}
      end
    rescue
      exception ->
        Logger.error("Feature access checker raised",
          user_id: user_id,
          feature: feature,
          exception: exception,
          kind: :error,
          stacktrace: __STACKTRACE__
        )

        {:error, :feature_access_checker_failed}
    end
  end

  def check_access(user_id, feature) do
    Logger.warning("Feature access check received invalid inputs",
      user_id: user_id,
      feature: feature
    )

    {:error, :feature_access_checker_failed}
  end

  @doc """
  Whether the host may see and configure meeting payments.

  `{:error, :stripe_required}` counts as allowed: the plan includes the feature
  and the host simply has not connected a charges-enabled Stripe account yet,
  so the settings must stay reachable for them to connect one. Whether a price
  may actually be *persisted* without a live account is a separate question,
  answered by the meeting-type changeset.

  Four call sites — the dashboard init hook, the integrations hub, the payments
  controller and the meeting-type form — each carried their own copy of this
  decision and cited three different, mutually inconsistent authorities for it,
  one of which holds no gate at all. This is the authority.
  """
  @spec meeting_payments_allowed?(integer()) :: boolean()
  def meeting_payments_allowed?(user_id) do
    case check_access(user_id, :meeting_payments) do
      :ok -> true
      {:error, :stripe_required} -> true
      _denied -> false
    end
  end
end
