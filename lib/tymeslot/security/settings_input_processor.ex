defmodule Tymeslot.Security.SettingsInputProcessor do
  @moduledoc """
  Dashboard settings input validation and sanitization.

  Provides specialized validation for profile settings forms including
  full name, username, timezone, and other profile-related inputs.
  """

  alias Tymeslot.Security.FieldValidators.FullNameValidator
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias Tymeslot.Security.SecurityLogger
  alias Tymeslot.Security.UniversalSanitizer

  @doc """
  Validates full name update input with security requirements.

  ## Parameters
  - `full_name` - The full name input string
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_full_name}` | `{:error, validation_error}`
  """
  @spec validate_full_name_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_full_name_update(full_name, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case FullNameValidator.validate(full_name) do
      :ok ->
        # Apply universal sanitization
        case UniversalSanitizer.sanitize_and_validate(full_name,
               allow_html: false,
               metadata: metadata
             ) do
          {:ok, sanitized_name} ->
            SecurityLogger.log_security_event("settings_full_name_validation_success", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent],
              user_id: metadata[:user_id]
            })

            {:ok, sanitized_name}

          {:error, reason} ->
            SecurityLogger.log_security_event("settings_full_name_validation_failure", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent],
              user_id: metadata[:user_id],
              error: reason
            })

            {:error, reason}
        end

      {:error, error} ->
        SecurityLogger.log_security_event("settings_full_name_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error
        })

        {:error, error}
    end
  end

  @doc """
  Validates username input with security requirements.

  ## Parameters
  - `username` - The username input string
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_username}` | `{:error, validation_error}`
  """
  @spec validate_username_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_username_update(username, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case UsernameValidator.validate(username) do
      :ok ->
        # Apply universal sanitization
        case UniversalSanitizer.sanitize_and_validate(username,
               allow_html: false,
               metadata: metadata
             ) do
          {:ok, sanitized_username} ->
            SecurityLogger.log_security_event("settings_username_validation_success", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent],
              user_id: metadata[:user_id],
              username: sanitized_username
            })

            {:ok, sanitized_username}

          {:error, reason} ->
            SecurityLogger.log_security_event("settings_username_validation_failure", %{
              ip_address: metadata[:ip],
              user_agent: metadata[:user_agent],
              user_id: metadata[:user_id],
              username: username,
              error: reason
            })

            {:error, reason}
        end

      {:error, error} ->
        SecurityLogger.log_security_event("settings_username_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          username: username,
          error: error
        })

        {:error, error}
    end
  end

  @doc """
  Validates timezone selection input.

  ## Parameters
  - `timezone` - Selected timezone string
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_timezone}` | `{:error, validation_error}`
  """
  @spec validate_timezone_update(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_timezone_update(timezone, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_timezone} <-
           UniversalSanitizer.sanitize_and_validate(timezone,
             allow_html: false,
             metadata: metadata
           ),
         :ok <- validate_timezone_format(sanitized_timezone) do
      SecurityLogger.log_security_event("settings_timezone_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        timezone: sanitized_timezone
      })

      {:ok, sanitized_timezone}
    else
      {:error, reason} ->
        SecurityLogger.log_security_event("settings_timezone_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          timezone: timezone,
          error: reason
        })

        {:error, reason}
    end
  end

  @doc """
  Validates avatar upload file parameters.

  ## Parameters
  - `file_params` - Map containing file upload parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, validated_params}` | `{:error, validation_error}`
  """
  @spec validate_avatar_upload(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def validate_avatar_upload(file_params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_file_type(file_params),
         :ok <- validate_file_size(file_params),
         :ok <- validate_file_name(file_params) do
      SecurityLogger.log_security_event("settings_avatar_upload_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        file_name: Map.get(file_params, "client_name", "unknown")
      })

      {:ok, file_params}
    else
      {:error, reason} ->
        SecurityLogger.log_security_event("settings_avatar_upload_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          file_name: Map.get(file_params, "client_name", "unknown"),
          error: reason
        })

        {:error, reason}
    end
  end

  # Private helper functions

  defp validate_timezone_format(timezone) when is_binary(timezone) do
    # Check for valid timezone format (e.g., "America/New_York", "UTC", "Europe/London")
    if String.match?(timezone, ~r/^[A-Za-z_]+\/[A-Za-z_]+$/) or timezone in ["UTC", "GMT"] do
      :ok
    else
      {:error, "Invalid timezone format"}
    end
  end

  defp validate_timezone_format(_), do: {:error, "Timezone must be a string"}

  defp validate_file_type(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        extension =
          filename
          |> Path.extname()
          |> String.downcase()

        if extension in [".jpg", ".jpeg", ".png", ".gif", ".webp"] do
          :ok
        else
          {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}
        end
    end
  end

  defp validate_file_size(file_params) do
    case Map.get(file_params, "size") do
      nil ->
        # Size validation will be handled by Phoenix upload system
        :ok

      size when is_integer(size) ->
        # 10MB
        max_size = 10_000_000

        if size <= max_size do
          :ok
        else
          {:error, "File too large. Maximum size is 10MB"}
        end

      _ ->
        {:error, "Invalid file size"}
    end
  end

  defp validate_file_name(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        cond do
          String.contains?(filename, ["../", "..\\", "\0"]) ->
            {:error, "Invalid file name"}

          String.match?(filename, ~r/[<>:"\\|?*]/) ->
            {:error, "Invalid file name"}

          String.length(filename) > 255 ->
            {:error, "File name too long"}

          true ->
            :ok
        end
    end
  end
end
