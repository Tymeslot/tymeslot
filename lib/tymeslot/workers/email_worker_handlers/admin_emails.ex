defmodule Tymeslot.Workers.EmailWorkerHandlers.AdminEmails do
  @moduledoc """
  Handles admin alert email actions.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
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
        Logger.info("Admin alert email delivered",
          category: category,
          recipient: recipient
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to deliver admin alert email",
          category: category,
          error: inspect(reason)
        )

        DeliveryOutcome.from_error(reason, "Failed to deliver admin alert")
    end
  end

  defp severity_atom("info"), do: :info
  defp severity_atom("warning"), do: :warning
  defp severity_atom("error"), do: :error
  defp severity_atom(_other), do: :warning
end
