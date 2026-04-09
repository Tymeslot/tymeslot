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

  @doc """
  Builds the args map for an admin alert job, including the SHA-256 dedup hash
  derived from the category + message.
  """
  @spec build_args(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: map()
  def build_args(recipient, category, severity, message, metadata) do
    %{
      "action" => "send_admin_alert",
      "recipient" => recipient,
      "category" => category,
      "severity" => to_string(severity),
      "message" => message,
      "metadata" => serialize_metadata(metadata),
      "alert_hash" => compute_alert_hash(category, message)
    }
  end

  @doc """
  Inserts an admin alert job into Oban with a 24-hour dedup window.

  Identical alerts (same recipient + category + message hash) within the
  window are silently dropped via Oban's uniqueness constraint, so a
  persistent issue produces at most one email per day for the same content.
  """
  @spec schedule(
          recipient :: String.t(),
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: :ok | {:error, String.t()}
  def schedule(recipient, category, severity, message, metadata) do
    args = build_args(recipient, category, severity, message, metadata)

    result =
      args
      |> EmailWorker.new(
        queue: :emails,
        priority: 3,
        unique: [
          period: @dedup_period_seconds,
          fields: [:args, :queue],
          keys: [:action, :recipient, :alert_hash]
        ]
      )
      |> Oban.insert()

    handle_insert_result(result, category, args["alert_hash"])
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
