defmodule Tymeslot.Workers.EmailWorkerHandlers.AdminEmails do
  @moduledoc """
  Handles admin alert email actions: a single alert, and the daily digest or
  the error roll-up.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

  @spec handle_admin_alert(%{String.t() => term()}) ::
          :ok | {:error, term()}
  def handle_admin_alert(%{
        "recipient" => recipient,
        "category" => category,
        "severity" => severity_str,
        "message" => message,
        "metadata" => metadata
      }) do
    severity = severity_atom(severity_str)

    case Config.email_service_module().send_admin_alert(
           recipient,
           category,
           severity,
           message,
           metadata
         ) do
      {:ok, _result} ->
        Logger.info("Admin alert email delivered", category: category)

        :ok

      {:error, reason} ->
        Logger.error("Failed to deliver admin alert email",
          category: category,
          error: LogFormat.reason(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to deliver admin alert")
    end
  end

  @spec handle_admin_alert_digest(%{String.t() => term()}) :: :ok | {:error, term()}
  def handle_admin_alert_digest(%{"recipient" => recipient} = args) do
    digest = Map.take(args, ["kind", "entries", "omitted", "deployment"])

    case Config.email_service_module().send_admin_alert_digest(recipient, digest) do
      {:ok, _result} ->
        Logger.info("Admin alert digest email delivered",
          entries: length(Map.get(digest, "entries", []))
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to deliver admin alert digest email",
          error: LogFormat.reason(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to deliver admin alert digest")
    end
  end

  defp severity_atom("info"), do: :info
  defp severity_atom("warning"), do: :warning
  defp severity_atom("error"), do: :error
  defp severity_atom(_other), do: :warning
end
