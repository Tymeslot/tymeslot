defmodule Tymeslot.Security.OnboardingInputProcessor do
  @moduledoc """
  Onboarding-specific input validation and sanitization.

  Provides specialized validation for onboarding forms with
  enhanced security logging and profile-specific validation.
  """

  alias Tymeslot.Security.FieldValidators.FullNameValidator
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Security.SecurityLogger

  @doc """
  Validates basic settings form input (full name, username).

  ## Parameters
  - `params` - Basic settings form parameters (full_name, username)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_basic_settings(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_basic_settings(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case InputProcessor.validate_form(
           params,
           [
             {"full_name", FullNameValidator},
             {"username", Tymeslot.Security.FieldValidators.UsernameValidator}
           ],
           metadata: metadata,
           universal_opts: [allow_html: false]
         ) do
      {:ok, sanitized_params} ->
        SecurityLogger.log_security_event("onboarding_basic_settings_validation_success", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent]
        })

        {:ok, sanitized_params}

      {:error, errors} ->
        SecurityLogger.log_security_event("onboarding_basic_settings_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates scheduling preferences input (numeric selections).

  ## Parameters
  - `params` - Scheduling preferences parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_scheduling_preferences(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_scheduling_preferences(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    # First validate with universal sanitization
    case InputProcessor.validate_form(
           params,
           [],
           metadata: metadata,
           universal_opts: [allow_html: false]
         ) do
      {:ok, sanitized_params} ->
        # Then validate specific scheduling values
        case validate_scheduling_values(sanitized_params) do
          :ok ->
            SecurityLogger.log_security_event("onboarding_scheduling_validation_success", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent]
            })

            {:ok, sanitized_params}

          {:error, errors} ->
            SecurityLogger.log_security_event("onboarding_scheduling_validation_failure", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent],
              errors: Map.keys(errors)
            })

            {:error, errors}
        end

      {:error, errors} ->
        SecurityLogger.log_security_event("onboarding_scheduling_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates timezone selection input.

  ## Parameters
  - `timezone` - Selected timezone string
  - `opts` - Options including metadata for logging
  """
  @spec validate_timezone_selection(String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def validate_timezone_selection(timezone, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_timezone_format(timezone) do
      :ok ->
        SecurityLogger.log_security_event("onboarding_timezone_validation_success", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          timezone: timezone
        })

        {:ok, timezone}

      {:error, error} ->
        SecurityLogger.log_security_event("onboarding_timezone_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          timezone: timezone,
          error: error
        })

        {:error, %{timezone: error}}
    end
  end

  # Private helper functions

  defp validate_scheduling_values(params) do
    validations = [
      {"buffer_minutes", &validate_buffer_minutes/1, :buffer_minutes},
      {"advance_booking_days", &validate_advance_booking_days/1, :advance_booking_days},
      {"min_advance_hours", &validate_min_advance_hours/1, :min_advance_hours}
    ]

    errors =
      validations
      |> Enum.flat_map(fn {key, validator, error_key} ->
        with {:ok, value} <- Map.fetch(params, key),
             {:error, error} <- validator.(value) do
          [{error_key, error}]
        else
          :error -> []
          :ok -> []
          {:ok, _result} -> []
        end
      end)
      |> Map.new()

    if map_size(errors) == 0, do: :ok, else: {:error, errors}
  end

  defp validate_buffer_minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {minutes, ""} -> validate_buffer_minutes(minutes)
      _other -> {:error, "Buffer minutes must be a valid number"}
    end
  end

  defp validate_buffer_minutes(minutes) when is_integer(minutes) do
    if minutes >= 0 and minutes <= 120 do
      :ok
    else
      {:error, "Buffer minutes must be between 0 and 120"}
    end
  end

  defp validate_buffer_minutes(_arg), do: {:error, "Buffer minutes must be a number"}

  defp validate_advance_booking_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> validate_advance_booking_days(days)
      _other -> {:error, "Advance booking days must be a valid number"}
    end
  end

  defp validate_advance_booking_days(days) when is_integer(days) do
    if days >= 1 and days <= 365 do
      :ok
    else
      {:error, "Advance booking days must be between 1 and 365"}
    end
  end

  defp validate_advance_booking_days(_arg), do: {:error, "Advance booking days must be a number"}

  defp validate_min_advance_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {hours, ""} -> validate_min_advance_hours(hours)
      _other -> {:error, "Minimum advance hours must be a valid number"}
    end
  end

  defp validate_min_advance_hours(hours) when is_integer(hours) do
    if hours >= 0 and hours <= 168 do
      :ok
    else
      {:error, "Minimum advance hours must be between 0 and 168"}
    end
  end

  defp validate_min_advance_hours(_arg), do: {:error, "Minimum advance hours must be a number"}

  defp validate_timezone_format(timezone) when is_binary(timezone) do
    # Check for basic timezone format (e.g., "America/New_York", "UTC", "Europe/London")
    if String.match?(timezone, ~r/^[A-Za-z_]+\/[A-Za-z_]+$/) or timezone in ["UTC", "GMT"] do
      :ok
    else
      {:error, "Invalid timezone format"}
    end
  end

  defp validate_timezone_format(_arg), do: {:error, "Timezone must be a string"}
end
