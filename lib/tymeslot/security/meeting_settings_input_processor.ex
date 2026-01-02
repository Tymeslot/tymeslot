defmodule Tymeslot.Security.MeetingSettingsInputProcessor do
  @moduledoc """
  Meeting settings input validation and sanitization.

  Provides specialized validation for meeting settings forms including
  meeting type creation/editing and scheduling settings configuration.
  """

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}

  @doc """
  Validates meeting type form input (name, duration, description).

  ## Parameters
  - `params` - Map containing meeting type form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_meeting_type_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_meeting_type_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_name} <- validate_meeting_name(params["name"], metadata),
         {:ok, sanitized_duration} <- validate_meeting_duration(params["duration"], metadata),
         {:ok, sanitized_description} <-
           validate_meeting_description(params["description"], metadata) do
      SecurityLogger.log_security_event("meeting_type_form_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id]
      })

      {:ok,
       %{
         "name" => sanitized_name,
         "duration" => sanitized_duration,
         "description" => sanitized_description
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("meeting_type_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Field-level validation for the meeting type form. Validates only the provided field.

  Returns {:ok, sanitized_value} | {:error, %{field => message}}
  """
  @spec validate_meeting_type_field(:name | :duration | :description, any(), keyword()) ::
          {:ok, String.t()} | {:error, map()}
  def validate_meeting_type_field(field, value, opts \\ [])

  def validate_meeting_type_field(:name, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_name(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{name: _} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:duration, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_duration(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{duration: _} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:description, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_description(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{description: _} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(_other, _value, _opts), do: {:error, %{base: "Invalid field"}}

  @doc """
  Validates buffer minutes setting input.

  ## Parameters
  - `buffer_str` - String containing buffer minutes value
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_value}` | `{:error, validation_error}`
  """
  @spec validate_buffer_minutes(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_buffer_minutes(buffer_str, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_input} <-
           UniversalSanitizer.sanitize_and_validate(buffer_str,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, validated_buffer} <-
           validate_numeric_range(sanitized_input, 0, 120, "Buffer minutes") do
      SecurityLogger.log_security_event("buffer_minutes_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        value: validated_buffer
      })

      {:ok, to_string(validated_buffer)}
    else
      {:error, error_msg} ->
        SecurityLogger.log_security_event("buffer_minutes_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error_msg
        })

        {:error, error_msg}
    end
  end

  @doc """
  Validates advance booking days setting input.

  ## Parameters
  - `days_str` - String containing advance booking days value
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_value}` | `{:error, validation_error}`
  """
  @spec validate_advance_booking_days(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_advance_booking_days(days_str, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_input} <-
           UniversalSanitizer.sanitize_and_validate(days_str,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, validated_days} <-
           validate_numeric_range(sanitized_input, 1, 365, "Advance booking days") do
      SecurityLogger.log_security_event("advance_booking_days_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        value: validated_days
      })

      {:ok, to_string(validated_days)}
    else
      {:error, error_msg} ->
        SecurityLogger.log_security_event("advance_booking_days_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error_msg
        })

        {:error, error_msg}
    end
  end

  @doc """
  Validates minimum advance hours setting input.

  ## Parameters
  - `hours_str` - String containing minimum advance hours value
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_value}` | `{:error, validation_error}`
  """
  @spec validate_min_advance_hours(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_min_advance_hours(hours_str, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_input} <-
           UniversalSanitizer.sanitize_and_validate(hours_str,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, validated_hours} <-
           validate_numeric_range(sanitized_input, 0, 168, "Minimum advance hours") do
      SecurityLogger.log_security_event("min_advance_hours_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        value: validated_hours
      })

      {:ok, to_string(validated_hours)}
    else
      {:error, error_msg} ->
        SecurityLogger.log_security_event("min_advance_hours_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error_msg
        })

        {:error, error_msg}
    end
  end

  # Private helper functions

  defp validate_meeting_name(nil, _metadata), do: {:error, %{name: "Meeting name is required"}}
  defp validate_meeting_name("", _metadata), do: {:error, %{name: "Meeting name is required"}}

  defp validate_meeting_name(name, metadata) when is_binary(name) do
    case UniversalSanitizer.sanitize_and_validate(name, allow_html: false, metadata: metadata) do
      {:ok, sanitized_name} ->
        cond do
          String.length(sanitized_name) > 100 ->
            {:error, %{name: "Meeting name must be 100 characters or less"}}

          String.length(String.trim(sanitized_name)) < 2 ->
            {:error, %{name: "Meeting name must be at least 2 characters"}}

          true ->
            {:ok, String.trim(sanitized_name)}
        end

      {:error, error} ->
        {:error, %{name: error}}
    end
  end

  defp validate_meeting_name(_, _metadata) do
    {:error, %{name: "Meeting name must be text"}}
  end

  defp validate_meeting_duration(nil, _metadata),
    do: {:error, %{duration: "Duration is required"}}

  defp validate_meeting_duration("", _metadata), do: {:error, %{duration: "Duration is required"}}

  defp validate_meeting_duration(duration_str, metadata) when is_binary(duration_str) do
    case UniversalSanitizer.sanitize_and_validate(duration_str,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_duration} ->
        validate_duration_value(sanitized_duration)

      {:error, error} ->
        {:error, %{duration: error}}
    end
  end

  defp validate_meeting_duration(_, _metadata) do
    {:error, %{duration: "Duration must be a number"}}
  end

  defp validate_duration_value(sanitized_duration) do
    case Integer.parse(sanitized_duration) do
      {duration, ""} ->
        validate_duration_constraints(duration)

      _ ->
        {:error, %{duration: "Duration must be a valid number of minutes"}}
    end
  end

  defp validate_duration_constraints(duration) when duration < 5 do
    {:error, %{duration: "Duration must be at least 5 minutes"}}
  end

  defp validate_duration_constraints(duration) when duration > 480 do
    {:error, %{duration: "Duration cannot exceed 8 hours (480 minutes)"}}
  end

  defp validate_duration_constraints(duration) when rem(duration, 5) != 0 do
    {:error, %{duration: "Duration must be divisible by 5 minutes"}}
  end

  defp validate_duration_constraints(duration) do
    {:ok, to_string(duration)}
  end

  defp validate_meeting_description(nil, _metadata), do: {:ok, ""}
  defp validate_meeting_description("", _metadata), do: {:ok, ""}

  defp validate_meeting_description(description, metadata) when is_binary(description) do
    case UniversalSanitizer.sanitize_and_validate(description,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_description} ->
        if String.length(sanitized_description) > 500 do
          {:error, %{description: "Description must be 500 characters or less"}}
        else
          {:ok, String.trim(sanitized_description)}
        end

      {:error, error} ->
        {:error, %{description: error}}
    end
  end

  defp validate_meeting_description(_, _metadata) do
    {:error, %{description: "Description must be text"}}
  end

  defp validate_numeric_range(value_str, min, max, field_name) do
    case Integer.parse(value_str) do
      {value, ""} when value >= min and value <= max ->
        {:ok, value}

      {value, ""} when value < min ->
        {:error, "#{field_name} must be at least #{min}"}

      {value, ""} when value > max ->
        {:error, "#{field_name} cannot exceed #{max}"}

      _ ->
        {:error, "#{field_name} must be a valid number"}
    end
  end
end
