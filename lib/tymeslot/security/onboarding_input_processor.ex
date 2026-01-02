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
          {:ok, _} -> []
        end
      end)
      |> Map.new()

    if map_size(errors) == 0, do: :ok, else: {:error, errors}
  end

  defp validate_buffer_minutes(value) when is_binary(value) do
    case Integer.parse(value) do
      {minutes, ""} -> validate_buffer_minutes(minutes)
      _ -> {:error, "Buffer minutes must be a valid number"}
    end
  end

  defp validate_buffer_minutes(minutes) when is_integer(minutes) do
    if minutes >= 0 and minutes <= 120 do
      :ok
    else
      {:error, "Buffer minutes must be between 0 and 120"}
    end
  end

  defp validate_buffer_minutes(_), do: {:error, "Buffer minutes must be a number"}

  defp validate_advance_booking_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> validate_advance_booking_days(days)
      _ -> {:error, "Advance booking days must be a valid number"}
    end
  end

  defp validate_advance_booking_days(days) when is_integer(days) do
    if days >= 1 and days <= 365 do
      :ok
    else
      {:error, "Advance booking days must be between 1 and 365"}
    end
  end

  defp validate_advance_booking_days(_), do: {:error, "Advance booking days must be a number"}

  defp validate_min_advance_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {hours, ""} -> validate_min_advance_hours(hours)
      _ -> {:error, "Minimum advance hours must be a valid number"}
    end
  end

  defp validate_min_advance_hours(hours) when is_integer(hours) do
    if hours >= 0 and hours <= 168 do
      :ok
    else
      {:error, "Minimum advance hours must be between 0 and 168"}
    end
  end

  defp validate_min_advance_hours(_), do: {:error, "Minimum advance hours must be a number"}

  defp validate_timezone_format(timezone) when is_binary(timezone) do
    # Check for basic timezone format (e.g., "America/New_York", "UTC", "Europe/London")
    if String.match?(timezone, ~r/^[A-Za-z_]+\/[A-Za-z_]+$/) or timezone in ["UTC", "GMT"] do
      :ok
    else
      {:error, "Invalid timezone format"}
    end
  end

  defp validate_timezone_format(_), do: {:error, "Timezone must be a string"}
end

defmodule Tymeslot.Security.FieldValidators.UsernameValidator do
  @moduledoc """
  Username field validation for onboarding.

  Validates username format, length, and character restrictions
  for creating public scheduling URLs.
  """

  @username_min_length 3
  @username_max_length 30
  @username_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc """
  Validates username with specific error messages.

  ## Examples

      iex> validate("john_smith")
      :ok
      
      iex> validate("ab")
      {:error, "Username must be at least 3 characters long"}
      
      iex> validate("john@smith")
      {:error, "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(username, opts \\ [])

  def validate(nil, _opts), do: {:error, "Username is required"}
  def validate("", _opts), do: {:error, "Username is required"}

  def validate(username, opts) when is_binary(username) do
    min_length = Keyword.get(opts, :min_length, @username_min_length)
    max_length = Keyword.get(opts, :max_length, @username_max_length)

    trimmed_username = String.trim(username)

    with :ok <- validate_length(trimmed_username, min_length, max_length),
         :ok <- validate_format(trimmed_username) do
      validate_reserved_words(trimmed_username)
    end
  end

  def validate(_username, _opts) do
    {:error, "Username must be a text value"}
  end

  # Private helper functions

  defp validate_length(username, min_length, max_length) do
    length = String.length(username)

    cond do
      length < min_length ->
        {:error, "Username must be at least #{min_length} characters long"}

      length > max_length ->
        {:error, "Username must be at most #{max_length} characters long"}

      true ->
        :ok
    end
  end

  defp validate_format(username) do
    if Regex.match?(@username_regex, username) do
      :ok
    else
      {:error,
       "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"}
    end
  end

  defp validate_reserved_words(username) do
    lowercase_username = String.downcase(username)

    reserved_words = [
      "admin",
      "api",
      "www",
      "mail",
      "ftp",
      "login",
      "signup",
      "auth",
      "dashboard",
      "profile",
      "settings",
      "help",
      "support",
      "contact",
      "about",
      "privacy",
      "terms",
      "blog",
      "news",
      "home",
      "index",
      "root",
      "test",
      "demo"
    ]

    if lowercase_username in reserved_words do
      {:error, "This username is reserved and cannot be used"}
    else
      :ok
    end
  end
end
