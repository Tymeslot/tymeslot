defmodule Tymeslot.Security.FormValidation do
  @moduledoc """
  Form validation for Tymeslot.
  Validates data integrity and format requirements.
  Uses Sanitizer module for all sanitization tasks.
  """

  require Logger
  alias Tymeslot.Profiles
  alias Tymeslot.Security.UniversalSanitizer

  @doc """
  Validates and sanitizes booking form parameters.
  Returns {:ok, sanitized_params} or {:error, errors}.
  """
  @spec validate_booking_form(map()) :: {:ok, map()} | {:error, list({atom(), String.t()})}
  def validate_booking_form(params) do
    Logger.info("Validating booking form", param_keys: Map.keys(params))

    # First sanitize the params
    sanitized_params = sanitize_booking_form_params(params)

    # Then validate the sanitized params
    case validate_booking_params(sanitized_params) do
      {:ok, validated_params} ->
        Logger.info("Booking form validation successful")
        {:ok, validated_params}

      {:error, errors} ->
        Logger.warning("Booking form validation failed", errors: inspect(errors))
        {:error, errors}
    end
  end

  @doc """
  Just sanitizes booking params without validation.
  """
  @spec sanitize_booking_params(map()) :: {:ok, map()}
  def sanitize_booking_params(params) do
    {:ok, sanitize_booking_form_params(params)}
  end

  # Private helper for sanitizing booking form parameters
  defp sanitize_booking_form_params(params) do
    %{
      "name" => sanitize_name(params["name"]),
      "email" => sanitize_email(params["email"]),
      "message" => sanitize_message(params["message"])
    }
  end

  defp sanitize_name(input) when is_binary(input) do
    case UniversalSanitizer.sanitize_and_validate(input, allow_html: false, on_too_long: :truncate) do
      {:ok, sanitized} ->
        sanitized
        |> String.trim()
        |> normalize_whitespace()

      {:error, _} ->
        ""
    end
  end

  defp sanitize_name(_), do: ""

  defp sanitize_email(input) when is_binary(input) do
    case UniversalSanitizer.sanitize_and_validate(input, allow_html: false, on_too_long: :truncate) do
      {:ok, sanitized} ->
        sanitized
        |> String.trim()
        |> String.downcase()

      {:error, _} ->
        ""
    end
  end

  defp sanitize_email(_), do: ""

  defp sanitize_message(input) when is_binary(input) do
    case UniversalSanitizer.sanitize_and_validate(input, allow_html: true, on_too_long: :truncate) do
      {:ok, sanitized} ->
        sanitized
        |> String.trim()
        |> normalize_whitespace()

      {:error, _} ->
        ""
    end
  end

  defp sanitize_message(_), do: ""

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Validates booking form parameters after sanitization.
  """
  @spec validate_booking_params(map()) :: {:ok, map()} | {:error, list({atom(), String.t()})}
  def validate_booking_params(params) do
    errors = []

    errors = validate_name(params["name"], errors)
    errors = validate_email(params["email"], errors)
    errors = validate_message(params["message"], errors)

    case errors do
      [] -> {:ok, params}
      _ -> {:error, errors}
    end
  end

  # Private validation functions

  defp validate_name(name, errors) when is_binary(name) do
    name = String.trim(name)

    cond do
      String.length(name) == 0 ->
        [{:name, "Name is required"} | errors]

      String.length(name) < 2 ->
        [{:name, "Name must be at least 2 characters"} | errors]

      String.length(name) > 100 ->
        [{:name, "Name must be less than 100 characters"} | errors]

      not valid_name_format?(name) ->
        [{:name, "Name contains invalid characters"} | errors]

      true ->
        errors
    end
  end

  defp validate_name(_, errors) do
    [{:name, "Name is required"} | errors]
  end

  defp validate_email(email, errors) when is_binary(email) do
    email = String.trim(email)

    cond do
      String.length(email) == 0 ->
        [{:email, "Email is required"} | errors]

      String.length(email) > 254 ->
        [{:email, "Email address is too long"} | errors]

      not valid_email_format?(email) ->
        [{:email, "Please enter a valid email address"} | errors]

      true ->
        errors
    end
  end

  defp validate_email(_, errors) do
    [{:email, "Email is required"} | errors]
  end

  defp validate_message(message, errors) when is_binary(message) do
    message = String.trim(message)

    cond do
      String.length(message) > 2000 ->
        [{:message, "Message must be less than 2000 characters"} | errors]

      not valid_message_format?(message) ->
        [{:message, "Message contains invalid content"} | errors]

      true ->
        errors
    end
  end

  defp validate_message(nil, errors), do: errors
  defp validate_message("", errors), do: errors

  defp validate_message(_, errors) do
    [{:message, "Invalid message format"} | errors]
  end

  # Format validation functions

  defp valid_name_format?(name) do
    # Allow letters, spaces, hyphens, apostrophes, and common international characters
    Regex.match?(~r/^[\p{L}\s\-'\.]+$/u, name)
  end

  defp valid_email_format?(email) do
    # Comprehensive email validation regex
    email_regex =
      ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/

    Regex.match?(email_regex, email) and valid_email_structure?(email)
  end

  defp valid_email_structure?(email) do
    parts = String.split(email, "@")

    case parts do
      [local, domain] ->
        valid_local_part?(local) and valid_domain_part?(domain)

      _ ->
        false
    end
  end

  defp valid_local_part?(local) do
    byte_size(local) <= 64 and byte_size(local) > 0
  end

  defp valid_domain_part?(domain) do
    domain_parts = String.split(domain, ".")

    byte_size(domain) <= 253 and
      length(domain_parts) >= 2 and
      Enum.all?(domain_parts, fn part ->
        byte_size(part) > 0 and byte_size(part) <= 63 and
          Regex.match?(~r/^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$/, part)
      end)
  end

  defp valid_message_format?(message) do
    # Check for potentially dangerous patterns
    dangerous_patterns = [
      ~r/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/mi,
      ~r/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/mi,
      ~r/javascript:/i,
      ~r/vbscript:/i,
      ~r/data:text\/html/i,
      ~r/on\w+\s*=/i
    ]

    result =
      not Enum.any?(dangerous_patterns, fn pattern ->
        if Regex.match?(pattern, message) do
          Logger.warning("Dangerous pattern detected in message", pattern: inspect(pattern))
          true
        else
          false
        end
      end)

    result
  end

  @doc """
  Validates duration parameter from URL.
  """
  @spec validate_duration(term()) :: {:ok, 15 | 30 | 60} | {:error, String.t()}
  def validate_duration(duration) when is_binary(duration) do
    case duration do
      "15" -> {:ok, 15}
      "30" -> {:ok, 30}
      "60" -> {:ok, 60}
      _ -> {:error, "Invalid duration"}
    end
  end

  def validate_duration(_), do: {:error, "Invalid duration"}

  @doc """
  Validates date parameter from URL.
  """
  @spec validate_date(term()) :: {:ok, Date.t()} | {:error, String.t()}
  def validate_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        today = Date.utc_today()

        cond do
          Date.compare(date, today) == :lt ->
            Logger.warning("Date validation failed: past date", date: date_string)
            {:error, "Date cannot be in the past"}

          Date.diff(date, today) > 365 ->
            Logger.warning("Date validation failed: too far in future", date: date_string)
            {:error, "Date cannot be more than a year in the future"}

          true ->
            Logger.debug("Date validation successful", date: date_string)
            {:ok, date}
        end

      {:error, _} ->
        Logger.error("Date validation failed: invalid format", date: date_string)
        {:error, "Invalid date format"}
    end
  end

  def validate_date(_), do: {:error, "Invalid date"}

  @doc """
  Validates time parameter from URL.
  """
  @spec validate_time(term()) :: {:ok, Time.t()} | {:error, String.t()}
  def validate_time(time_string) when is_binary(time_string) do
    case Time.from_iso8601(time_string <> ":00") do
      {:ok, time} -> {:ok, time}
      {:error, _} -> {:error, "Invalid time format"}
    end
  end

  def validate_time(_), do: {:error, "Invalid time"}

  @doc """
  Gets validation errors for display in forms.
  """
  @spec get_field_errors(list({atom(), String.t()}), atom()) :: [String.t()]
  def get_field_errors(errors, field) do
    errors
    |> Enum.filter(fn {error_field, _} -> error_field == field end)
    |> Enum.map(fn {_, message} -> message end)
  end

  @doc """
  Checks if form has any validation errors.
  """
  @spec has_errors?(list()) :: boolean()
  def has_errors?(errors), do: length(errors) > 0

  @doc """
  Checks if a specific field has validation errors.
  """
  @spec field_has_errors?(list({atom(), String.t()}), atom()) :: boolean()
  def field_has_errors?(errors, field) do
    Enum.any?(errors, fn {error_field, _} -> error_field == field end)
  end

  @doc """
  Validates a single field by name.
  """
  @spec validate_field(atom(), term()) :: :ok | {:error, String.t()}
  def validate_field(:username, value) do
    # Delegate to Profiles for username validation
    case Profiles.validate_username_format(value) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  def validate_field(field, _value) do
    Logger.warning("No validation defined for field", field: field)
    :ok
  end
end
