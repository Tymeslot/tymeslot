defmodule Tymeslot.Security.RateLimiter.Bookings do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  # Per-recipient limits keyed on the attendee email address. The per-IP
  # `check_booking_submission/1` bucket does not stop an attacker rotating
  # source IPs to bomb one mailbox with confirmation emails; this caps the
  # number of bookings that can target a single address regardless of source.
  # Tuned generously — a real attendee rarely receives several booking
  # confirmations in an hour — while still bounding amplification hard.
  @recipient_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 20, 24 * 60 * 60_000},
    {"1w", 50, 7 * 24 * 60 * 60_000}
  ]

  @spec check_webhook_endpoint(String.t()) :: :ok | {:error, :rate_limited}
  def check_webhook_endpoint(client_ip) do
    Helpers.check_rate_limit("webhook:#{client_ip}", 100, :timer.minutes(10))
  end

  @spec check_booking_submission(String.t()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def check_booking_submission(client_ip) do
    Helpers.check_rate("booking_submit:#{client_ip}", 1_200_000, 10)
  end

  @spec check_booking_recipient(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_booking_recipient(email) do
    # Normalise so case/whitespace variants of one address share a bucket.
    normalised = email |> String.trim() |> String.downcase()

    Helpers.check_multi_bucket_limits([
      {"booking_recipient:#{normalised}", @recipient_limits, "booking"}
    ])
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
