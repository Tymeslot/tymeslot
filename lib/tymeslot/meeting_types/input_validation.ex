defmodule Tymeslot.MeetingTypes.InputValidation do
  @moduledoc """
  Meeting settings input validation and sanitisation.

  Provides specialised validation for the meeting type form. A schedule's
  booking policy is validated by `Tymeslot.Availability.PolicyValidation`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}
  alias Tymeslot.Validation.Constraints

  @min_duration Constraints.duration_minutes_range().first
  @max_duration Constraints.duration_minutes_range().last

  @doc """
  Validates meeting type form input (name, duration, description, icon).

  ## Parameters
  - `params` - Map containing meeting type form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_meeting_type_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_meeting_type_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    validations =
      [
        {:name, params["name"]},
        {:duration, params["duration"]},
        {:slot_interval, params["slot_interval"]},
        {:description, params["description"]},
        {:icon, params["icon"]},
        {:calendar_integration_id, params["calendar_integration_id"]},
        {:target_calendar_id, params["target_calendar_id"]},
        {:reminder_config, params["reminder_config"]}
      ] ++ max_participants_validation(params)

    case run_validations(validations, metadata) do
      {:ok, sanitized_params} ->
        log_validation_result("success", metadata)
        {:ok, sanitized_params}

      {:error, errors} ->
        log_validation_result("failure", metadata, errors)
        {:error, errors}
    end
  end

  @doc """
  Single-field validation for the meeting type form.

  Validates and sanitises one field at a time. Used for inline field
  validation in LiveView forms.

  ## Parameters
  - `field` - The field atom (`:name`, `:duration`, `:slot_interval`,
    `:description`, `:icon`, `:reminder_config`)
  - `value` - The raw input value
  - `metadata` - Security metadata map (ip, user_agent, user_id)

  ## Returns
  - `{:ok, sanitised_value}` | `{:error, %{field => message}}`
  """
  @spec validate_field(atom(), any(), map()) :: {:ok, any()} | {:error, map()}
  def validate_field(:name, value, metadata), do: validate_meeting_name(value, metadata)
  def validate_field(:duration, value, metadata), do: validate_meeting_duration(value, metadata)

  def validate_field(:slot_interval, value, metadata),
    do: validate_meeting_slot_interval(value, metadata)

  def validate_field(:description, value, metadata),
    do: validate_meeting_description(value, metadata)

  def validate_field(:icon, value, metadata), do: validate_icon(value, metadata)

  def validate_field(:calendar_integration_id, value, metadata),
    do: validate_calendar_integration_id(value, metadata)

  def validate_field(:target_calendar_id, value, metadata),
    do: validate_target_calendar_id(value, metadata)

  def validate_field(:reminder_config, value, metadata),
    do: ReminderValidation.validate_reminder_config(value, metadata)

  # The canonical param, which the form serialises as "1" for a solo type.
  def validate_field(:max_participants, value, metadata),
    do: validate_max_participants(value, metadata, Constraints.max_participants_range())

  # The visible participant-limit input, which only exists while group
  # bookings are switched on. Its floor is 2: a limit of 1 is the toggle
  # being off, and accepting it here would store a solo type behind an
  # enabled toggle, stranding any bookings already taken on the slot.
  def validate_field(:group_participants, value, metadata),
    do: validate_max_participants(value, metadata, Constraints.group_participants_range())

  def validate_field(_other_field, _value, _metadata),
    do: {:error, %{base: dgettext("dashboard_meeting_form", "Invalid field")}}

  # --- Private helpers ---

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

  defp validate_numeric_setting(value_str, min, max, label, event_name, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, sanitized_input} <-
           UniversalSanitizer.sanitize_and_validate(value_str,
             allow_html: false,
             metadata: metadata
           ),
         {:ok, validated_value} <-
           validate_numeric_range(sanitized_input, min, max, label) do
      SecurityLogger.log_security_event("#{event_name}_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id],
        value: validated_value
      })

      {:ok, validated_value}
    else
      {:error, error_msg} ->
        SecurityLogger.log_security_event("#{event_name}_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          error: error_msg
        })

        {:error, error_msg}
    end
  end

  defp validate_meeting_name(nil, _metadata),
    do: {:error, %{name: dgettext("dashboard_meeting_form", "Meeting name is required")}}

  defp validate_meeting_name("", _metadata),
    do: {:error, %{name: dgettext("dashboard_meeting_form", "Meeting name is required")}}

  defp validate_meeting_name(name, metadata) when is_binary(name) do
    case UniversalSanitizer.sanitize_and_validate(name, mode: :plain_text, metadata: metadata) do
      {:ok, sanitized_name} ->
        trimmed = String.trim(sanitized_name)

        slug =
          trimmed |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

        cond do
          String.length(trimmed) > 100 ->
            {:error,
             %{
               name:
                 dgettext("dashboard_meeting_form", "Meeting name must be 100 characters or less")
             }}

          String.length(trimmed) < 2 ->
            {:error,
             %{
               name:
                 dgettext("dashboard_meeting_form", "Meeting name must be at least 2 characters")
             }}

          slug == "" ->
            {:error,
             %{
               name:
                 dgettext(
                   "dashboard_meeting_form",
                   "Meeting name must contain at least one letter or number"
                 )
             }}

          true ->
            {:ok, trimmed}
        end

      {:error, error} ->
        {:error, %{name: error}}
    end
  end

  defp validate_meeting_name(_invalid, _metadata) do
    {:error, %{name: dgettext("dashboard_meeting_form", "Meeting name must be text")}}
  end

  defp validate_meeting_duration(nil, _metadata),
    do: {:error, %{duration: dgettext("dashboard_meeting_form", "Duration is required")}}

  defp validate_meeting_duration("", _metadata),
    do: {:error, %{duration: dgettext("dashboard_meeting_form", "Duration is required")}}

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
    {:error, %{duration: dgettext("dashboard_meeting_form", "Duration must be a number")}}
  end

  defp validate_duration_value(sanitized_duration) do
    case Integer.parse(sanitized_duration) do
      {duration, ""} ->
        validate_duration_constraints(duration)

      _invalid ->
        {:error,
         %{
           duration:
             dgettext("dashboard_meeting_form", "Duration must be a valid number of minutes")
         }}
    end
  end

  defp validate_duration_constraints(duration) when duration < @min_duration do
    {:error,
     %{
       duration:
         dgettext("dashboard_meeting_form", "Duration must be at least %{min} minutes",
           min: @min_duration
         )
     }}
  end

  defp validate_duration_constraints(duration) when duration > @max_duration do
    {:error,
     %{
       duration:
         dgettext("dashboard_meeting_form", "Duration cannot exceed 24 hours (%{max} minutes)",
           max: @max_duration
         )
     }}
  end

  defp validate_duration_constraints(duration)
       when rem(duration, unquote(Constraints.duration_step_minutes())) != 0 do
    {:error,
     %{
       duration:
         dgettext("dashboard_meeting_form", "Duration must be a multiple of %{step} minutes",
           step: Constraints.duration_step_minutes()
         )
     }}
  end

  defp validate_duration_constraints(duration) do
    {:ok, to_string(duration)}
  end

  # Blank means "use the meeting type's own duration" — the field is optional,
  # unlike duration.
  defp validate_meeting_slot_interval(nil, _metadata), do: {:ok, ""}
  defp validate_meeting_slot_interval("", _metadata), do: {:ok, ""}

  defp validate_meeting_slot_interval(interval_str, metadata) when is_binary(interval_str) do
    case UniversalSanitizer.sanitize_and_validate(interval_str,
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_interval} ->
        validate_slot_interval_value(sanitized_interval)

      {:error, error} ->
        {:error, %{slot_interval: error}}
    end
  end

  defp validate_meeting_slot_interval(_invalid, _metadata) do
    {:error,
     %{slot_interval: dgettext("dashboard_meeting_form", "Slot interval must be a number")}}
  end

  defp validate_slot_interval_value(""), do: {:ok, ""}

  defp validate_slot_interval_value(sanitized_interval) do
    case Integer.parse(sanitized_interval) do
      {interval, ""} ->
        validate_slot_interval_constraints(interval)

      _invalid ->
        {:error,
         %{
           slot_interval:
             dgettext("dashboard_meeting_form", "Slot interval must be a valid number of minutes")
         }}
    end
  end

  defp validate_slot_interval_constraints(interval) do
    range = Constraints.slot_interval_minutes_range()

    cond do
      interval < range.first ->
        {:error,
         %{
           slot_interval:
             dgettext("dashboard_meeting_form", "Slot interval must be at least %{min} minutes",
               min: range.first
             )
         }}

      interval > range.last ->
        {:error,
         %{
           slot_interval:
             dgettext("dashboard_meeting_form", "Slot interval cannot exceed %{max} minutes",
               max: range.last
             )
         }}

      true ->
        {:ok, to_string(interval)}
    end
  end

  defp validate_meeting_description(nil, _metadata), do: {:ok, ""}
  defp validate_meeting_description("", _metadata), do: {:ok, ""}

  defp validate_meeting_description(description, metadata) when is_binary(description) do
    case UniversalSanitizer.sanitize_and_validate(description,
           mode: :plain_text,
           metadata: metadata
         ) do
      {:ok, sanitized_description} ->
        if String.length(sanitized_description) > Constraints.description_max_length() do
          {:error,
           %{
             description:
               dgettext("dashboard_meeting_form", "Description must be %{max} characters or less",
                 max: Constraints.description_max_length()
               )
           }}
        else
          {:ok, String.trim(sanitized_description)}
        end

      {:error, error} ->
        {:error, %{description: error}}
    end
  end

  defp validate_meeting_description(_invalid, _metadata) do
    {:error, %{description: dgettext("dashboard_meeting_form", "Description must be text")}}
  end

  defp validate_icon(nil, _metadata), do: {:ok, "none"}
  defp validate_icon("", _metadata), do: {:ok, "none"}

  defp validate_icon(icon, metadata) when is_binary(icon) do
    case UniversalSanitizer.sanitize_and_validate(icon, allow_html: false, metadata: metadata) do
      {:ok, sanitized_icon} ->
        if sanitized_icon in MeetingTypeSchema.valid_icons() do
          {:ok, sanitized_icon}
        else
          {:error, %{icon: dgettext("dashboard_meeting_form", "Invalid icon selected")}}
        end

      {:error, error} ->
        {:error, %{icon: error}}
    end
  end

  defp validate_icon(_invalid, _metadata) do
    {:error, %{icon: dgettext("dashboard_meeting_form", "Invalid icon format")}}
  end

  defp validate_calendar_integration_id(nil, _metadata), do: {:ok, nil}
  defp validate_calendar_integration_id("", _metadata), do: {:ok, nil}

  defp validate_calendar_integration_id(id, _metadata) do
    case id do
      id when is_integer(id) ->
        {:ok, id}

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} ->
            {:ok, int}

          _invalid ->
            {:error,
             %{
               calendar_integration:
                 dgettext("dashboard_meeting_form", "Invalid calendar account selected")
             }}
        end

      _invalid ->
        {:error,
         %{
           calendar_integration:
             dgettext("dashboard_meeting_form", "Invalid calendar account format")
         }}
    end
  end

  defp validate_target_calendar_id(nil, _metadata), do: {:ok, nil}
  defp validate_target_calendar_id("", _metadata), do: {:ok, nil}

  # The id is the provider's own (a CalDAV path, a Google or Outlook calendar
  # id), so it is checked and never rewritten: `:strict` mode would strip
  # `0x<hex>` runs and everything from `--` onwards, pointing bookings at a
  # calendar that does not exist or is not the one picked.
  defp validate_target_calendar_id(id, metadata) when is_binary(id) do
    UniversalSanitizer.sanitize_and_validate(id, mode: :plain_text, metadata: metadata)
  end

  defp validate_target_calendar_id(_invalid, _metadata) do
    {:error,
     %{target_calendar: dgettext("dashboard_meeting_form", "Invalid target calendar format")}}
  end

  # Only validated when the form actually posts the key — an absent key means
  # the sanitised params omit it too, so Ecto's cast leaves the stored value
  # untouched (same convention as custom_fields and the payment fields).
  defp max_participants_validation(%{"max_participants" => value}),
    do: [{:max_participants, value}]

  defp max_participants_validation(_params), do: []

  defp validate_max_participants(value, metadata, range) when is_binary(value) do
    case validate_numeric_setting(
           value,
           range.first,
           range.last,
           "Participant limit",
           "max_participants",
           metadata: metadata
         ) do
      {:ok, validated} -> {:ok, to_string(validated)}
      {:error, _message} -> {:error, %{max_participants: participant_limit_message(value, range)}}
    end
  end

  defp validate_max_participants(_invalid, _metadata, _range),
    do:
      {:error,
       %{
         max_participants:
           dgettext("dashboard_meeting_form", "Participant limit must be a valid number")
       }}

  # Re-derives which bound was violated so the user-facing message is
  # translated, without changing `validate_numeric_setting/6`'s plain-English
  # message (shared with schedule-settings validators outside this form).
  defp participant_limit_message(value, range) do
    case Integer.parse(value) do
      {parsed, ""} when parsed < range.first ->
        dgettext("dashboard_meeting_form", "Participant limit must be at least %{min}",
          min: range.first
        )

      {parsed, ""} when parsed > range.last ->
        dgettext("dashboard_meeting_form", "Participant limit cannot exceed %{max}",
          max: range.last
        )

      _invalid ->
        dgettext("dashboard_meeting_form", "Participant limit must be a valid number")
    end
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
