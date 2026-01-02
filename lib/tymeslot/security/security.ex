defmodule Tymeslot.Security.Security do
  @moduledoc """
  Additional security utilities for Tymeslot.
  Provides protection against common attack vectors.
  """

  require Logger

  alias Phoenix.LiveView
  alias Tymeslot.Security.RateLimiter

  @doc """
  Validates URL parameters to prevent injection attacks.
  """
  @spec validate_url_params(map()) :: boolean()
  def validate_url_params(params) do
    dangerous_patterns = [
      ~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi,
      ~r/javascript:/i,
      ~r/data:text\/html/i,
      ~r/vbscript:/i,
      ~r/on\w+\s*=/i,
      # Path traversal
      ~r/\.\.\//,
      # Null bytes
      ~r/\0/,
      # CRLF injection
      ~r/\r|\n/
    ]

    result =
      Enum.all?(params, fn
        {_key, nil} ->
          true

        {key, val} when is_binary(val) ->
          if Enum.any?(dangerous_patterns, &Regex.match?(&1, val)) do
            Logger.warning("Dangerous pattern detected in URL parameter",
              key: key,
              pattern_detected: true
            )

            false
          else
            true
          end

        {_key, _val} ->
          true
      end)

    unless result do
      Logger.error("URL parameter validation failed", params_count: map_size(params))
    end

    result
  end

  @doc """
  Sanitizes timezone input to prevent injection.
  """
  @spec validate_timezone(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_timezone(timezone) when is_binary(timezone) do
    # Only allow valid timezone format: Region/City or UTC
    timezone_pattern = ~r/^[A-Za-z0-9_]+\/[A-Za-z0-9_]+$|^UTC$|^Etc\/UTC$/

    cond do
      String.length(timezone) > 100 ->
        Logger.warning("Timezone validation failed: too long",
          timezone_length: String.length(timezone)
        )

        {:error, "Timezone too long"}

      not Regex.match?(timezone_pattern, timezone) ->
        Logger.warning("Timezone validation failed: invalid format")
        {:error, "Invalid timezone format"}

      true ->
        Logger.debug("Timezone validated successfully")
        {:ok, timezone}
    end
  end

  @spec validate_timezone(term()) :: {:error, String.t()}
  def validate_timezone(timezone) do
    Logger.warning("Timezone validation failed: not a string", value_type: inspect(timezone))
    {:error, "Invalid timezone"}
  end

  @doc """
  Enhanced IP tracking for better rate limiting.
  """
  @spec get_client_identifier(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_client_identifier(socket) do
    # Combine multiple factors for better tracking
    ip = get_real_ip(socket)
    user_agent = get_user_agent(socket)

    Logger.debug("Creating client identifier")

    # Create a hash to avoid storing full user agent
    identifier_string = "#{ip}:#{hash_user_agent(user_agent)}"
    Base.encode16(:crypto.hash(:sha256, identifier_string))
  end

  defp get_real_ip(socket) do
    case LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        to_string(:inet.ntoa(address))

      _ ->
        # Check headers for forwarded IP
        case LiveView.get_connect_info(socket, :x_headers) do
          headers when is_list(headers) ->
            get_forwarded_ip(headers) || "unknown"

          _ ->
            "unknown"
        end
    end
  end

  defp get_user_agent(socket) do
    with headers when is_list(headers) <- LiveView.get_connect_info(socket, :x_headers),
         ua when is_binary(ua) <- find_header(headers, "user-agent") do
      ua
    else
      _ -> "unknown"
    end
  end

  defp find_header(headers, name) when is_list(headers) and is_binary(name) do
    lname = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == lname, do: value, else: nil

      _ ->
        nil
    end)
  end

  defp hash_user_agent(user_agent) do
    String.slice(Base.encode16(:crypto.hash(:md5, user_agent)), 0, 8)
  end

  defp get_forwarded_ip(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) in ["x-real-ip", "x-forwarded-for", "cf-connecting-ip"] do
        String.trim(List.first(String.split(value, ",")))
      end
    end)
  end

  @doc """
  Validates business hours to prevent scheduling outside allowed times.
  """
  @spec validate_business_hours(Time.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  def validate_business_hours(time, timezone) do
    # Convert to the business timezone (adjust as needed)
    business_timezone = "Europe/Kyiv"

    try do
      case DateTime.new(Date.utc_today(), time, timezone) do
        {:ok, user_datetime} ->
          case DateTime.shift_zone(user_datetime, business_timezone) do
            {:ok, business_datetime} ->
              business_time = DateTime.to_time(business_datetime)

              # Check if within business hours (9 AM - 5 PM)
              if Time.compare(business_time, ~T[09:00:00]) != :lt and
                   Time.compare(business_time, ~T[17:00:00]) == :lt do
                {:ok, business_datetime}
              else
                {:error, "Time outside business hours"}
              end

            _ ->
              {:error, "Invalid timezone conversion"}
          end

        _ ->
          {:error, "Invalid time"}
      end
    rescue
      _ -> {:error, "Time validation failed"}
    end
  end

  @doc """
  Prevents calendar enumeration attacks by limiting queries.
  """
  @spec validate_calendar_access(Date.t(), String.t()) :: {:ok, Date.t()} | {:error, String.t()}
  def validate_calendar_access(date, user_identifier) do
    # Rate limit calendar queries per user
    bucket_key = "calendar_query:#{user_identifier}"

    case RateLimiter.check_rate(bucket_key, 60_000, 10) do
      {:allow, _} ->
        # Additional date validation
        today = Date.utc_today()
        max_future_date = Date.add(today, 365)

        cond do
          Date.compare(date, today) == :lt ->
            Logger.warning("Calendar access denied: past date",
              date: date,
              user_identifier: user_identifier
            )

            {:error, "Cannot query past dates"}

          Date.compare(date, max_future_date) == :gt ->
            Logger.warning("Calendar access denied: date too far in future",
              date: date,
              max_allowed: max_future_date,
              user_identifier: user_identifier
            )

            {:error, "Cannot query dates more than a year in advance"}

          true ->
            Logger.debug("Calendar access allowed", date: date)
            {:ok, date}
        end

      {:deny, _} ->
        Logger.error("Calendar access rate limit exceeded",
          user_identifier: user_identifier,
          bucket_key: bucket_key
        )

        {:error, "Too many calendar queries"}
    end
  end

  @doc """
  Prevents email enumeration by consistent response times.
  """
  @spec consistent_response_delay() :: :ok
  def consistent_response_delay do
    # Add small random delay to prevent timing attacks
    delay = :rand.uniform(100) + 50
    Logger.debug("Adding security delay", delay_ms: delay)
    Process.sleep(delay)
  end

  @doc """
  Logs security events for monitoring.
  """
  @spec log_security_event(String.t(), map(), term()) :: :ok
  def log_security_event(event_type, details, _socket) do
    Logger.warning("Security Event: #{event_type}",
      details: details,
      timestamp: DateTime.utc_now()
    )
  end
end
