defmodule Tymeslot.Security.RateLimiter.PublicEndpoints do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_freebusy_feed(String.t()) :: :ok | {:error, :rate_limited}
  def check_freebusy_feed(client_ip),
    do: Helpers.check_rate_limit("freebusy:#{client_ip}", 60, :timer.minutes(1))

  @spec check_meeting_calendar_feed(String.t()) :: :ok | {:error, :rate_limited}
  def check_meeting_calendar_feed(client_ip),
    do: Helpers.check_rate_limit("meeting_ics:#{client_ip}", 60, :timer.minutes(1))

  @spec check_healthcheck(String.t()) :: :ok | {:error, :rate_limited}
  def check_healthcheck(client_ip),
    do: Helpers.check_rate_limit("healthcheck:#{client_ip}", 30, :timer.minutes(1))
end
