defmodule Tymeslot.MeetingTypes.InputValidation do
  @moduledoc """
  Meeting settings input validation and sanitization.

  Provides specialized validation for meeting settings forms including
  meeting type creation/editing and scheduling settings configuration.
  """

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Validation.Constraints

  @doc """
  Validates meeting type form input (name, duration, description, icon, mode).

  ## Parameters
  - `params` - Map containing meeting type form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_meeting_type_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_meeting_type_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validations = [
      {:name, params["name"]},
      {:duration, params["duration"]},
      {:description, params["description"]},
      {:icon, params["icon"]},
      {:meeting_mode, params["meeting_mode"]},
      {:calendar_integration_id, params["calendar_integration_id"]},
      {:target_calendar_id, params["target_calendar_id"]},
      {:reminder_config, params["reminder_config"]}
    ]

    case run_validations(validations, metadata) do
      {:ok, sanitized_params} ->
        log_validation_result("success", metadata)
        {:ok, sanitized_params}

      {:error, errors} ->
        log_validation_result("failure", metadata, errors)
        {:error, errors}
    end
  end

  defp run_validations(validations, metadata) do
    {sanitized_acc, error_acc} =
      Enum.reduce(validations, {%{}, %{}}, fn {field, value}, {s_acc, e_acc} ->
        case validate_field(field, value, metadata) do
          {:ok, sanitized} ->
            {Map.put(s_acc, Atom.to_string(field), sanitized), e_acc}

          {:error, err} ->
            {s_acc, Map.merge(e_acc, err)}
        end
      end)

    if error_acc == %{} do
      {:ok, sanitized_acc}
    else
      {:error, error_acc}
    end
  end

  defp validate_field(:name, value, metadata), do: validate_meeting_name(value, metadata)
  defp validate_field(:duration, value, metadata), do: validate_meeting_duration(value, metadata)

  defp validate_field(:description, value, metadata),
    do: validate_meeting_description(value, metadata)

  defp validate_field(:icon, value, metadata), do: validate_icon(value, metadata)
  defp validate_field(:meeting_mode, value, metadata), do: validate_meeting_mode(value, metadata)

  defp validate_field(:calendar_integration_id, value, metadata),
    do: validate_calendar_integration_id(value, metadata)

  defp validate_field(:target_calendar_id, value, metadata),
    do: validate_target_calendar_id(value, metadata)

  defp validate_field(:reminder_config, value, metadata),
    do: validate_reminder_config(value, metadata)

  defp log_validation_result(status, metadata, errors \\ nil) do
    event_name = "meeting_type_form_validation_#{status}"

    log_params = %{
      ip_address: metadata[:ip],
      user_agent: metadata[:user_agent],
      user_id: metadata[:user_id]
    }

    log_params =
      if errors, do: Map.put(log_params, :errors, Map.keys(errors)), else: log_params

    SecurityLogger.log_security_event(event_name, log_params)
  end

  @doc """
  Field-level validation for the meeting type form. Validates only the provided field.

  Returns {:ok, sanitized_value} | {:error, %{field => message}}
  """
  @spec validate_meeting_type_field(
          :name | :duration | :description | :icon | :meeting_mode | :reminder_config,
          any(),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, map()}
  def validate_meeting_type_field(field, value, opts \\ [])

  def validate_meeting_type_field(:name, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_name(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{name: _name_error} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:duration, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_duration(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{duration: _duration_error} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:description, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_description(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{description: _description_error} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:icon, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_icon(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{icon: _icon_error} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:meeting_mode, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_meeting_mode(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, %{meeting_mode: _mode_error} = err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(:reminder_config, value, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    case validate_reminder_config(value, metadata) do
      {:ok, sanitized} -> {:ok, sanitized}
      {:error, err} -> {:error, err}
    end
  end

  def validate_meeting_type_field(_other_field, _value, _opts),
    do: {:error, %{base: "Invalid field"}}

  @doc """
  Validates buffer minutes setting input.

  ## Parameters
  - `buffer_str` - String containing buffer minutes value
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, validated_integer}` | `{:error, validation_error}`
  """
  @spec validate_buffer_minutes(String.t(), keyword()) :: {:ok, integer()} | {:error, String.t()}
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

      {:ok, validated_buffer}
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
  - `{:ok, validated_integer}` | `{:error, validation_error}`
  """
  @spec validate_advance_booking_days(String.t(), keyword()) ::
          {:ok, integer()} | {:error, String.t()}
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

      {:ok, validated_days}
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
  - `{:ok, validated_integer}` | `{:error, validation_error}`
  """
  @spec validate_min_advance_hours(String.t(), keyword()) ::
          {:ok, integer()} | {:error, String.t()}
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

      {:ok, validated_hours}
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
        trimmed = String.trim(sanitized_name)

        slug =
          trimmed |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

        cond do
          String.length(trimmed) > 100 ->
            {:error, %{name: "Meeting name must be 100 characters or less"}}

          String.length(trimmed) < 2 ->
            {:error, %{name: "Meeting name must be at least 2 characters"}}

          slug == "" ->
            {:error, %{name: "Meeting name must contain at least one letter or number"}}

          true ->
            {:ok, trimmed}
        end

      {:error, error} ->
        {:error, %{name: error}}
    end
  end

  defp validate_meeting_name(_invalid, _metadata) do
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

  defp validate_meeting_duration(_invalid, _metadata) do
    {:error, %{duration: "Duration must be a number"}}
  end

  defp validate_duration_value(sanitized_duration) do
    case Integer.parse(sanitized_duration) do
      {duration, ""} ->
        validate_duration_constraints(duration)

      _invalid ->
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
        if String.length(sanitized_description) > Constraints.description_max_length() do
          {:error,
           %{
             description:
               "Description must be #{Constraints.description_max_length()} characters or less"
           }}
        else
          {:ok, String.trim(sanitized_description)}
        end

      {:error, error} ->
        {:error, %{description: error}}
    end
  end

  defp validate_meeting_description(_invalid, _metadata) do
    {:error, %{description: "Description must be text"}}
  end

  defp validate_icon(nil, _metadata), do: {:ok, "none"}
  defp validate_icon("", _metadata), do: {:ok, "none"}

  defp validate_icon(icon, metadata) when is_binary(icon) do
    case UniversalSanitizer.sanitize_and_validate(icon, allow_html: false, metadata: metadata) do
      {:ok, sanitized_icon} ->
        if sanitized_icon in MeetingTypeSchema.valid_icons() do
          {:ok, sanitized_icon}
        else
          {:error, %{icon: "Invalid icon selected"}}
        end

      {:error, error} ->
        {:error, %{icon: error}}
    end
  end

  defp validate_icon(_invalid, _metadata) do
    {:error, %{icon: "Invalid icon format"}}
  end

  defp validate_meeting_mode(nil, _metadata), do: {:ok, "personal"}
  defp validate_meeting_mode("", _metadata), do: {:ok, "personal"}

  defp validate_meeting_mode(mode, metadata) when is_binary(mode) do
    case UniversalSanitizer.sanitize_and_validate(mode, allow_html: false, metadata: metadata) do
      {:ok, sanitized_mode} ->
        if sanitized_mode in ["personal", "video"] do
          {:ok, sanitized_mode}
        else
          {:error, %{meeting_mode: "Invalid meeting mode selected"}}
        end

      {:error, error} ->
        {:error, %{meeting_mode: error}}
    end
  end

  defp validate_meeting_mode(_invalid, _metadata) do
    {:error, %{meeting_mode: "Invalid meeting mode format"}}
  end

  defp validate_calendar_integration_id(nil, _metadata), do: {:ok, nil}
  defp validate_calendar_integration_id("", _metadata), do: {:ok, nil}

  defp validate_calendar_integration_id(id, _metadata) do
    case id do
      id when is_integer(id) ->
        {:ok, id}

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} -> {:ok, int}
          _invalid -> {:error, %{calendar_integration: "Invalid calendar account selected"}}
        end

      _invalid ->
        {:error, %{calendar_integration: "Invalid calendar account format"}}
    end
  end

  defp validate_target_calendar_id(nil, _metadata), do: {:ok, nil}
  defp validate_target_calendar_id("", _metadata), do: {:ok, nil}

  defp validate_target_calendar_id(id, metadata) when is_binary(id) do
    UniversalSanitizer.sanitize_and_validate(id, allow_html: false, metadata: metadata)
  end

  defp validate_target_calendar_id(_invalid, _metadata) do
    {:error, %{target_calendar: "Invalid target calendar format"}}
  end

  defp validate_reminder_config(nil, _metadata), do: {:ok, []}
  defp validate_reminder_config("", _metadata), do: {:ok, []}

  defp validate_reminder_config(reminder_config, _metadata) do
    with {:ok, reminders} <- parse_and_normalize_reminders(reminder_config),
         :ok <- validate_reminders_policy(reminders) do
      {:ok, reminders}
    else
      {:error, message} -> {:error, %{reminder_config: message}}
    end
  end

  defp parse_and_normalize_reminders(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> parse_and_normalize_reminders(decoded)
      _invalid -> {:error, "Invalid reminder settings format"}
    end
  end

  defp parse_and_normalize_reminders(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> parse_and_normalize_reminders()
  end

  defp parse_and_normalize_reminders(reminders) when is_list(reminders) do
    results = Enum.map(reminders, &ReminderUtils.normalize_reminder_string_keys/1)

    if Enum.any?(results, &match?({:error, _reason}, &1)) do
      {:error, "Reminder settings must include valid values and units"}
    else
      {:ok, Enum.map(results, fn {:ok, reminder} -> reminder end)}
    end
  end

  defp parse_and_normalize_reminders(_other), do: {:error, "Invalid reminder settings format"}

  defp validate_reminders_policy(reminders) do
    cond do
      length(reminders) > 3 ->
        {:error, "You can configure up to 3 reminders"}

      ReminderUtils.duplicate_reminders?(reminders) ->
        {:error, "Reminder settings must be unique"}

      Enum.any?(reminders, &reminder_exceeds_max?/1) ->
        {:error, "Reminders cannot be set for more than 1 year in advance"}

      true ->
        :ok
    end
  end

  # Max reminder: 1 year (365 days)
  defp reminder_exceeds_max?(%{value: v, unit: u}) do
    seconds = ReminderUtils.reminder_interval_seconds(v, u)
    seconds > 365 * 24 * 60 * 60
  end

  defp validate_numeric_range(value_str, min, max, field_name) do
    case Integer.parse(value_str) do
      {value, ""} when value >= min and value <= max ->
        {:ok, value}

      {value, ""} when value < min ->
        {:error, "#{field_name} must be at least #{min}"}

      {value, ""} when value > max ->
        {:error, "#{field_name} cannot exceed #{max}"}

      _invalid ->
        {:error, "#{field_name} must be a valid number"}
    end
  end
end
