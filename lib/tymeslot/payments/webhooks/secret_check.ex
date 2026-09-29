defmodule Tymeslot.Payments.Webhooks.SecretCheck do
  @moduledoc """
  Boot check that every Stripe webhook this deployment relies on can be
  verified.

  A webhook whose signing secret is missing is rejected on every delivery
  (`{:error, :not_configured}`, answered with a 503). Stripe retries and
  then gives up, so payments are taken but never recorded, and the only
  trace is an error line per delivery. This check says so once, at boot, as
  an `:error` log and a `:stripe_webhook_secret_missing` admin alert per
  missing secret. The per-delivery log lines stay as they are.

  A secret counts as required only when its endpoint carries events the
  deployment acts on, and only with a real Stripe key configured
  (`MeetingPayments.platform_configured?/0`, the same test the admin
  settings use before meeting payments can be switched on):

    * `STRIPE_WEBHOOK_SECRET` (the platform endpoint, read the way
      `Tymeslot.Payments.Webhooks.Delivery` reads it) when a subscription
      manager is configured, since the platform events drive subscriptions
      and their refunds and disputes;
    * `STRIPE_CONNECT_WEBHOOK_SECRET` (the Connect endpoint, read the way
      `Tymeslot.MeetingPayments.Webhooks.WebhookProcessor` reads it) when
      meeting payments are enabled, since those events record booking
      payments.
  """

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Payments.Config

  @platform_secret "STRIPE_WEBHOOK_SECRET"
  @connect_secret "STRIPE_CONNECT_WEBHOOK_SECRET"

  @doc """
  Logs and alerts for each required webhook secret that is missing, and
  returns their environment variable names.
  """
  @spec check() :: [String.t()]
  def check do
    run([
      {@platform_secret, &platform_required?/0, &platform_secret/0},
      {@connect_secret, &connect_required?/0, &connect_secret/0}
    ])
  end

  @doc """
  `check/0` for the Connect secret alone: the one an admin setting (meeting
  payments) can make required while the application runs.
  """
  @spec check_connect() :: [String.t()]
  def check_connect, do: run([{@connect_secret, &connect_required?/0, &connect_secret/0}])

  defp run(secrets) do
    missing = if MeetingPayments.platform_configured?(), do: missing_secrets(secrets), else: []
    Enum.each(missing, &report/1)
    missing
  end

  defp missing_secrets(secrets) do
    secrets
    |> Enum.filter(fn {_name, required?, read} -> required?.() and blank?(read.()) end)
    |> Enum.map(fn {name, _required?, _read} -> name end)
  end

  defp platform_required?, do: not is_nil(Config.subscription_manager())

  defp connect_required?,
    do: Application.get_env(:tymeslot, :meeting_payments_enabled, false) == true

  defp platform_secret, do: Config.stripe_provider().webhook_secret()
  defp connect_secret, do: Application.get_env(:tymeslot, :stripe_connect_webhook_secret)

  defp blank?(secret), do: not is_binary(secret) or String.trim(secret) == ""

  defp report(env_var) do
    summary = consequence(env_var)

    Logger.error("Stripe webhook secret is not configured",
      env_var: env_var,
      consequence: summary
    )

    AdminAlerts.report(:stripe_webhook_secret_missing,
      summary: summary,
      context: %{env_var: env_var}
    )
  end

  defp consequence(@platform_secret),
    do: "Stripe subscription, invoice and dispute webhooks are rejected, so none is recorded"

  defp consequence(@connect_secret),
    do: "Stripe Connect webhooks are rejected, so booking payments are not recorded"
end
