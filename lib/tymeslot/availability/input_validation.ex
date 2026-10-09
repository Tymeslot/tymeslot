defmodule Tymeslot.Availability.InputValidation do
  @moduledoc """
  Availability input validation and sanitization.

  Provides specialized validation for availability management forms including
  time inputs, break scheduling, and schedule management operations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Window
  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Utils.DateTimeUtils

  @typedoc "String-keyed params map for a time-range input (start/end as HH:MM strings)."
  @type time_range_params :: %{optional(String.t()) => String.t()}

  @typedoc "Validation error map with atom keys and human-readable error message values."
  @type validation_errors :: %{atom() => String.t()}

  @doc """
  Validates time range input for day hours (start and end times). The end may
  carry a `+1` suffix (`"02:00+1"`) to end on the next day.

  ## Parameters
  - `params` - Map containing start and end time strings
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_day_hours(%{String.t() => term()}, keyword()) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => String.t()}}
  def validate_day_hours(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validate_time_window(
      :day_hours,
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
  @spec validate_break_input(%{String.t() => term()}, keyword()) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => String.t()}}
  def validate_break_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validate_time_window(
      :break,
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
  @spec validate_quick_break_input(%{String.t() => term()}, keyword()) ::
          {:ok, %{String.t() => term()}} | {:error, %{atom() => String.t()}}
  def validate_quick_break_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_start} <-
           validate_time_input(params["start"], "start_time", metadata, :clock),
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
         mode,
         params,
         metadata,
         success_event,
         failure_event,
         post_processor
       )
       when is_function(post_processor, 3) do
    with {:ok, sanitized_start} <-
           validate_time_input(params["start"], "start_time", metadata, :clock),
         {:ok, sanitized_end} <-
           validate_time_input(params["end"], "end_time", metadata, end_format(mode)),
         :ok <- validate_time_range(mode, sanitized_start, sanitized_end),
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
        errors = %{start_time: error_msg, end_time: error_msg}
        log_validation_failure(failure_event, metadata, errors)
        {:error, errors}
    end
  end

  defp end_format(:day_hours), do: :window_end
  defp end_format(:break), do: :clock

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

  defp validate_time_input(time_input, field_name, metadata, format) do
    case UniversalSanitizer.sanitize_and_validate(time_input,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_time} ->
        case validate_time_format(sanitized_time, format) do
          :ok -> {:ok, sanitized_time}
          {:error, error} -> {:error, %{String.to_existing_atom(field_name) => error}}
        end

      {:error, error} ->
        {:error, %{String.to_existing_atom(field_name) => error}}
    end
  end

  defp validate_time_format(time_str, :clock) when is_binary(time_str) do
    case DateTimeUtils.parse_hhmm(time_str) do
      {:ok, _time} -> :ok
      {:error, _reason} -> {:error, invalid_time_message()}
    end
  end

  defp validate_time_format(time_str, :window_end) when is_binary(time_str) do
    case Window.parse_end(time_str) do
      {:ok, _end} -> :ok
      {:error, _reason} -> {:error, invalid_time_message()}
    end
  end

  defp validate_time_format(_arg, _format),
    do: {:error, dgettext("dashboard_availability", "Time must be a string")}

  defp invalid_time_message,
    do: dgettext("dashboard_availability", "Time must be in HH:MM format (e.g., 09:30)")

  defp validate_time_range(:day_hours, start_time, end_value) do
    with {:ok, start_parsed} <- DateTimeUtils.parse_hhmm(start_time),
         {:ok, {end_parsed, ends_next_day}} <- Window.parse_end(end_value) do
      cond do
        Window.valid?(start_parsed, end_parsed, ends_next_day) ->
          :ok

        ends_next_day ->
          {:error,
           dgettext(
             "dashboard_availability",
             "Hours that end the next day can last at most 24 hours"
           )}

        true ->
          {:error,
           dgettext(
             "dashboard_availability",
             "End time must be after start time. To run past midnight, pick an end time marked (+1)."
           )}
      end
    else
      _other -> {:error, dgettext("dashboard_availability", "Invalid time format")}
    end
  end

  # A break's order depends on its day's hours, which only the domain knows:
  # 23:30 to 00:30 is valid inside an overnight day. `Breaks` and the break
  # schema judge it, and the dashboard maps their errors
  # (`BreakHelpers.display_message/2`).
  defp validate_time_range(:break, _start_time, _end_time), do: :ok

  defp validate_break_label(nil, _metadata), do: {:ok, "Break"}
  defp validate_break_label("", _metadata), do: {:ok, "Break"}

  defp validate_break_label(label, metadata) when is_binary(label) do
    case UniversalSanitizer.sanitize_and_validate(label, mode: :plain_text, metadata: metadata) do
      {:ok, sanitized_label} ->
        cond do
          String.length(sanitized_label) > 50 ->
            {:error,
             %{
               label:
                 dgettext("dashboard_availability", "Break label must be 50 characters or less")
             }}

          String.trim(sanitized_label) == "" ->
            {:ok, "Break"}

          true ->
            {:ok, String.trim(sanitized_label)}
        end

      {:error, error} ->
        {:error, %{label: error}}
    end
  end

  defp validate_break_label(_invalid, _metadata) do
    {:error, %{label: dgettext("dashboard_availability", "Break label must be text")}}
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
            {:error,
             %{
               duration:
                 dgettext("dashboard_availability", "Duration must be greater than 0 minutes")
             }}

          {duration, ""} when duration > 480 ->
            {:error,
             %{
               duration:
                 dgettext(
                   "dashboard_availability",
                   "Duration cannot exceed 8 hours (480 minutes)"
                 )
             }}

          _invalid ->
            {:error,
             %{
               duration:
                 dgettext("dashboard_availability", "Duration must be a valid number of minutes")
             }}
        end

      {:error, error} ->
        {:error, %{duration: error}}
    end
  end

  defp parse_day_selections(day_selections) do
    day_selections
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case Integer.parse(segment) do
        {day, ""} ->
          {:cont, {:ok, [day | acc]}}

        _unparsable ->
          {:halt, {:error, dgettext("dashboard_availability", "Invalid day selection format")}}
      end
    end)
    |> filter_selected_days()
  end

  defp filter_selected_days({:error, _reason} = error), do: error

  defp filter_selected_days({:ok, parsed_days}) do
    days =
      parsed_days
      |> Enum.reverse()
      |> Enum.filter(&(&1 >= 1 and &1 <= 7))
      |> Enum.uniq()

    if Enum.empty?(days) do
      {:error, dgettext("dashboard_availability", "No valid days selected")}
    else
      {:ok, days}
    end
  end
end
