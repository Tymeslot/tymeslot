defmodule Tymeslot.Payments.Webhooks.WebhookUtils do
  @moduledoc """
  Utility functions for webhook handlers.
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Workers.SendConfiguredEmail

  @doc """
  Enqueues the email `config_key`'s template builds with `template_fun` for
  the user, followed by `args` (plain values and maps, carried in the job).
  The email goes out from a job (`Tymeslot.Workers.SendConfiguredEmail`), so
  a mail outage delays it rather than losing it; a template the deployment
  has not configured sends nothing.

  `opts` is kept for the callers' log messages; a failure to enqueue is
  logged with `:error_msg`.
  """
  @spec deliver_user_email(integer(), atom(), atom(), list(), keyword()) :: :ok
  def deliver_user_email(user_id, config_key, template_fun, args, opts) do
    case SendConfiguredEmail.enqueue(config_key, template_fun, {:user, user_id}, args) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(Keyword.get(opts, :error_msg, "Failed to enqueue email to user"),
          user_id: user_id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
