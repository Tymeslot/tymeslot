defmodule Tymeslot.Security.RateLimiter.Bookings do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_webhook_endpoint(String.t()) :: :ok | {:error, :rate_limited}
  def check_webhook_endpoint(client_ip) do
    Helpers.check_rate_limit("webhook:#{client_ip}", 100, :timer.minutes(10))
  end

  @spec check_booking_submission(String.t()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def check_booking_submission(client_ip) do
    Helpers.check_rate("booking_submit:#{client_ip}", 1_200_000, 10)
  end

  @spec check_meeting_cancel(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_meeting_cancel(client_ip) do
    Helpers.check_with_logging(
      "meeting_cancel:#{client_ip}",
      10,
      600_000,
      "meeting cancellation",
      client_ip
    )
  end

  @spec check_meeting_keep(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_meeting_keep(client_ip) do
    Helpers.check_with_logging(
      "meeting_keep:#{client_ip}",
      10,
      600_000,
      "meeting keep",
      client_ip
    )
  end
end
