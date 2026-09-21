defmodule Tymeslot.Security.RateLimiter.Calendar do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @event_move_limits [
    {"1m", 3, 60_000},
    {"5m", 5, 5 * 60_000},
    {"1h", 15, 60 * 60_000},
    {"1d", 30, 24 * 60 * 60_000}
  ]

  @spec check_event_edit(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_event_edit(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_with_logging(
      "calendar_event_edit:#{user_id}",
      30,
      300_000,
      "calendar event edit",
      to_string(user_id)
    )
  end

  def check_event_edit(user_id), do: Helpers.invalid_user_id("calendar event edit", user_id)

  @spec check_event_move(integer() | any()) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :invalid_user_id}
  def check_event_move(user_id) when is_integer(user_id) and user_id > 0 do
    Helpers.check_multi_bucket_limits([
      {"calendar_event_move:#{user_id}", @event_move_limits, "calendar event move"}
    ])
  end

  def check_event_move(user_id), do: Helpers.invalid_user_id("calendar event move", user_id)

  @doc """
  Limits the calendar push endpoints per source address.

  Google and Microsoft Graph deliver every tenant's notifications from a small
  pool of their own addresses, so one key here aggregates the whole instance's
  push traffic. That makes it a flood cap rather than a fair-use ceiling: a
  limit tight enough to bound a single tenant would throttle all of them at
  once, and Graph drops a subscription whose endpoint keeps refusing it. The
  per-integration `check_webhook/1` bucket is what bounds one tenant's work.
  """
  @spec check_push_endpoint(String.t()) :: :ok | {:error, :rate_limited}
  def check_push_endpoint(client_ip) do
    Helpers.check_rate_limit("calendar_push:#{client_ip}", 1_000, :timer.minutes(1))
  end

  @spec check_webhook(integer() | any()) :: :ok | {:error, :rate_limited}
  def check_webhook(id) when is_integer(id) and id > 0,
    do: Helpers.check_rate_limit("calendar_webhook:#{id}", 60, 60_000)

  # Reject 0, negative, non-integer, and nil ids rather than collapsing
  # them into a shared `calendar_webhook:0` bucket that any caller could
  # hammer through.
  def check_webhook(_id), do: {:error, :rate_limited}
end
