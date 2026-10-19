defmodule Tymeslot.Test.FailingMailerAdapter do
  @moduledoc """
  Swoosh adapter that fails every delivery with a configured reason.

  `Swoosh.Adapters.Test` always succeeds, which leaves the delivery error paths
  in `Tymeslot.Emails.Delivery` untestable through the real call chain. Point
  `Tymeslot.Mailer` at this adapter and set `:test_delivery_error` to the reason
  the provider would return, and `Delivery.deliver/1` classifies a genuine
  failure rather than a hand-built one.
  """

  @behaviour Swoosh.Adapter

  @default_error :econnrefused

  # `:test_delivery_attempts_to`, when set to a pid, is sent
  # `{:delivery_attempt, recipients}` for every attempt, so a test can count
  # how many times an email was really handed to the provider.
  @impl Swoosh.Adapter
  def deliver(email, _config) do
    with pid when is_pid(pid) <- Application.get_env(:tymeslot, :test_delivery_attempts_to),
         do: send(pid, {:delivery_attempt, Enum.map(email.to, &elem(&1, 1))})

    case error_for(email) do
      :raise -> raise "mailer adapter crashed"
      :exit -> exit(:mailer_adapter_exited)
      reason -> {:error, reason}
    end
  end

  # `:test_delivery_error` is one reason for every email, or a map from a
  # recipient address to its reason (`:raise` raises in the adapter, which the
  # circuit breaker turns into an error; `:exit` exits, which it does not, so
  # the whole run crashes), with
  # `:default` for the rest.
  defp error_for(email) do
    case Application.get_env(:tymeslot, :test_delivery_error, @default_error) do
      %{} = by_recipient ->
        [{_name, address} | _rest] = email.to
        Map.get(by_recipient, address, Map.get(by_recipient, :default, @default_error))

      reason ->
        reason
    end
  end

  @impl Swoosh.Adapter
  def validate_config(_config), do: :ok
end
