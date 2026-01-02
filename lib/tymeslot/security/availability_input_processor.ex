defmodule Tymeslot.Security.AvailabilityInputProcessor do
  @moduledoc """
  Availability input validation and sanitization.

  Provides specialized validation for availability management forms including
  time inputs, break scheduling, and schedule management operations.
  """

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}

  @doc """
  Validates time range input for day hours (start and end times).

  ## Parameters
  - `params` - Map containing start and end time strings
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_day_hours(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_day_hours(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validate_time_window(
      params,
      metadata,
      "availability_day_hours_validation_success",
      "availability_day_hours_validation_failure",
      fn sanitized_range, _params, _metadata -> {:ok, sanitized_range} end
    )
  end

  @doc """
  Validates break addition input (start time, end time, label).

  ## Parameters
  - `params` - Map containing break parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_break_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_break_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validate_time_window(
      params,
      metadata,
      "availability_break_validation_success",
      "availability_break_validation_failure",
      fn sanitized_range, full_params, meta ->
        with {:ok, sanitized_label} <- validate_break_label(full_params["label"], meta) do
          {:ok, Map.put(sanitized_range, "label", sanitized_label)}
        end
      end
    )
  end

  @doc """
  Validates quick break input (start time and duration).

  ## Parameters
  - `params` - Map containing quick break parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_quick_break_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_quick_break_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_start} <- validate_time_input(params["start"], "start_time", metadata),
         {:ok, sanitized_duration} <- validate_duration_input(params["duration"], metadata) do
      SecurityLogger.log_security_event("availability_quick_break_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id]
      })

      {:ok,
       %{
         "start" => sanitized_start,
         "duration" => sanitized_duration
       }}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("availability_quick_break_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates day selection for copy operations.

  ## Parameters
  - `day_selections` - String of comma-separated day numbers
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, validated_days}` | `{:error, validation_error}`
  """
  @spec validate_day_selections(String.t(), keyword()) :: {:ok, list()} | {:error, String.t()}
  def validate_day_selections(day_selections, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_input} <-
           UniversalSanitizer.sanitize_and_validate(day_selections,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, parsed_days} <- parse_day_selections(sanitized_input) do
      SecurityLogger.log_security_event("availability_day_selections_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        selected_days: parsed_days
      })

      {:ok, parsed_days}
    else
      {:error, error_msg} ->
        SecurityLogger.log_security_event("availability_day_selections_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error_msg
        })

        {:error, error_msg}
    end
  end

  # Private helper functions

  defp validate_time_window(
         params,
         metadata,
         success_event,
         failure_event,
         post_processor
       )
       when is_function(post_processor, 3) do
    with {:ok, sanitized_start} <- validate_time_input(params["start"], "start_time", metadata),
         {:ok, sanitized_end} <- validate_time_input(params["end"], "end_time", metadata),
         :ok <- validate_time_range(sanitized_start, sanitized_end),
         {:ok, enriched_result} <-
           post_processor.(
             %{"start" => sanitized_start, "end" => sanitized_end},
             params,
             metadata
           ) do
      log_validation_success(success_event, metadata)
      {:ok, enriched_result}
    else
      {:error, errors} when is_map(errors) ->
        log_validation_failure(failure_event, metadata, errors)
        {:error, errors}

      {:error, error_msg} ->
        errors = %{time_range: error_msg}
        log_validation_failure(failure_event, metadata, errors)
        {:error, errors}
    end
  end

  defp log_validation_success(event, metadata, extra \\ %{}) do
    SecurityLogger.log_security_event(event, Map.merge(base_metadata(metadata), extra))
  end

  defp log_validation_failure(event, metadata, errors, extra \\ %{}) do
    SecurityLogger.log_security_event(
      event,
      base_metadata(metadata)
      |> Map.merge(%{errors: Map.keys(errors)})
      |> Map.merge(extra)
    )
  end

  defp base_metadata(metadata) do
    %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent],
      user_id: metadata[:user_id]
    }
  end

  defp validate_time_input(time_input, field_name, metadata) do
    case UniversalSanitizer.sanitize_and_validate(time_input,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_time} ->
        case validate_time_format(sanitized_time) do
          :ok -> {:ok, sanitized_time}
          {:error, error} -> {:error, %{String.to_existing_atom(field_name) => error}}
        end

      {:error, error} ->
        {:error, %{String.to_existing_atom(field_name) => error}}
    end
  end

  defp validate_time_format(time_str) when is_binary(time_str) do
    # Validate HH:MM format (24-hour)
    case Regex.match?(~r/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/, time_str) do
      true ->
        # Additional validation - parse to ensure it's a valid time
        case Time.from_iso8601(time_str <> ":00") do
          {:ok, _time} -> :ok
          {:error, _} -> {:error, "Invalid time value"}
        end

      false ->
        {:error, "Time must be in HH:MM format (e.g., 09:30)"}
    end
  end

  defp validate_time_format(_), do: {:error, "Time must be a string"}

  defp validate_time_range(start_time, end_time) do
    with {:ok, start_parsed} <- Time.from_iso8601(start_time <> ":00"),
         {:ok, end_parsed} <- Time.from_iso8601(end_time <> ":00") do
      case Time.compare(start_parsed, end_parsed) do
        :lt -> :ok
        _ -> {:error, "End time must be after start time"}
      end
    else
      _ -> {:error, "Invalid time format"}
    end
  end

  defp validate_break_label(nil, _metadata), do: {:ok, "Break"}
  defp validate_break_label("", _metadata), do: {:ok, "Break"}

  defp validate_break_label(label, metadata) when is_binary(label) do
    case UniversalSanitizer.sanitize_and_validate(label, allow_html: false, metadata: metadata) do
      {:ok, sanitized_label} ->
        cond do
          String.length(sanitized_label) > 50 ->
            {:error, %{label: "Break label must be 50 characters or less"}}

          String.trim(sanitized_label) == "" ->
            {:ok, "Break"}

          true ->
            {:ok, String.trim(sanitized_label)}
        end

      {:error, error} ->
        {:error, %{label: error}}
    end
  end

  defp validate_break_label(_, _metadata) do
    {:error, %{label: "Break label must be text"}}
  end

  defp validate_duration_input(duration_input, metadata) do
    case UniversalSanitizer.sanitize_and_validate(duration_input,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_duration} ->
        case Integer.parse(sanitized_duration) do
          {duration, ""} when duration > 0 and duration <= 480 ->
            # Maximum 8 hours (480 minutes) for a break
            {:ok, to_string(duration)}

          {duration, ""} when duration <= 0 ->
            {:error, %{duration: "Duration must be greater than 0 minutes"}}

          {duration, ""} when duration > 480 ->
            {:error, %{duration: "Duration cannot exceed 8 hours (480 minutes)"}}

          _ ->
            {:error, %{duration: "Duration must be a valid number of minutes"}}
        end

      {:error, error} ->
        {:error, %{duration: error}}
    end
  end

  defp parse_day_selections(day_selections) do
    days =
      day_selections
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.to_integer/1)
      |> Enum.filter(&(&1 >= 1 and &1 <= 7))
      |> Enum.uniq()

    if Enum.empty?(days) do
      {:error, "No valid days selected"}
    else
      {:ok, days}
    end
  rescue
    ArgumentError ->
      {:error, "Invalid day selection format"}
  end
end
