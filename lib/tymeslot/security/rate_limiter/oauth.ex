defmodule Tymeslot.Security.RateLimiter.OAuth do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_initiation(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_initiation(ip) do
    Helpers.check_with_logging(
      "oauth_initiation:#{ip}",
      10,
      600_000,
      "OAuth initiation",
      ip
    )
  end

  @spec check_callback(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_callback(ip) do
    Helpers.check_with_logging("oauth_callback:#{ip}", 20, 120_000, "OAuth callback", ip)
  end

  @spec check_completion(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_completion(ip) do
    Helpers.check_with_logging(
      "oauth_completion:#{ip}",
      6,
      1_200_000,
      "OAuth completion",
      ip
    )
  end

  @spec check_registration(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_registration(ip) do
    Helpers.check_with_logging(
      "oauth_registration:#{ip}",
      6,
      1_200_000,
      "OAuth registration",
      ip
    )
  end
end
