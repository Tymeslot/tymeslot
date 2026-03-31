defmodule Tymeslot.Security.RateLimiter.Integrations do
  @moduledoc false

  alias Tymeslot.Security.RateLimiter.Helpers

  @spec check_caldav_connection(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_caldav_connection(ip) do
    Helpers.check_with_logging(
      "caldav_connection:#{ip}",
      20,
      600_000,
      "CalDAV connection test",
      ip
    )
  end

  @spec check_mirotalk_connection(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_mirotalk_connection(ip) do
    Helpers.check_with_logging(
      "mirotalk_connection:#{ip}",
      20,
      600_000,
      "MiroTalk connection test",
      ip
    )
  end

  @spec check_nextcloud_connection(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_nextcloud_connection(ip) do
    Helpers.check_with_logging(
      "nextcloud_connection:#{ip}",
      20,
      600_000,
      "Nextcloud connection test",
      ip
    )
  end

  @spec check_calendar_discovery(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_calendar_discovery(ip) do
    Helpers.check_with_logging(
      "calendar_discovery:#{ip}",
      30,
      600_000,
      "calendar discovery",
      ip
    )
  end
end
