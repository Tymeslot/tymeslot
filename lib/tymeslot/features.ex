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
end
