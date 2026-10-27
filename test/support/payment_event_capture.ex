defmodule Tymeslot.Test.PaymentEventCapture do
  @moduledoc """
  Captures the payment events the Stripe webhooks hand off.

  Installs a `:payment_event_handler` that sends every handed-off message,
  unchanged, to the calling test process, so a test asserts on it with
  `assert_received %{event: :charge_refunded, data: %{...}}`. Both config
  values are restored on test exit. A test that needs a different handler
  (a failing one, say) sets it after this setup.

      import Tymeslot.Test.PaymentEventCapture

      setup :capture_payment_events
  """

  import Tymeslot.ConfigTestHelpers

  defmodule Handler do
    @moduledoc false
    @behaviour Tymeslot.Payments.Behaviours.PaymentEventHandler

    @impl Tymeslot.Payments.Behaviours.PaymentEventHandler
    def handle_payment_event(message) do
      send(Application.fetch_env!(:tymeslot, :payment_event_capture_pid), message)
      :ok
    end
  end

  @doc "Setup callback routing handed-off payment events to the test process."
  @spec capture_payment_events(map()) :: :ok
  def capture_payment_events(_context \\ %{}) do
    setup_config(:tymeslot,
      payment_event_handler: Handler,
      payment_event_capture_pid: self()
    )
  end
end
