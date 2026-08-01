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

  @impl Swoosh.Adapter
  def deliver(_email, _config),
    do: {:error, Application.get_env(:tymeslot, :test_delivery_error, @default_error)}

  @impl Swoosh.Adapter
  def validate_config(_config), do: :ok
end
