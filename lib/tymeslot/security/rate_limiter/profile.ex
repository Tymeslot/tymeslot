defmodule Tymeslot.Security.RateLimiter.Profile do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_username_change(String.t()) :: :ok | {:error, :rate_limited}
  def check_username_change(identifier) do
    Helpers.check_rate_limit("username_change:#{identifier}", 6, 7_200_000)
  end

  @spec check_username_check(String.t()) :: :ok | {:error, :rate_limited}
  def check_username_check(identifier) do
    Helpers.check_rate_limit("username_check:#{identifier}", 60, 120_000)
  end
end
