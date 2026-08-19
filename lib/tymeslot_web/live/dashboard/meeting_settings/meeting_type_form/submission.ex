defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Submission do
  @moduledoc """
  Serialises `MeetingTypeForm` socket state into form params and persists it.

  Two responsibilities:

    * `build_params/1` mirrors the hidden inputs the form would post, but
      derives them straight from socket assigns. Auto-save relies on this so
      it never depends on a DOM round-trip — clicking a control updates an
      assign synchronously, and the next save reads that assign directly
      rather than racing the re-rendered hidden input.

    * `persist/4` runs the shared validate → merge → create/update pipeline
      used by both the explicit "Create" submit and edit-mode auto-save, so
      the two paths stay byte-for-byte identical.
  """

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.InputValidation
  alias Tymeslot.Utils.SanitizeMerge

  @doc """
  Builds the `meeting_type` params map from the form's socket assigns.

  The shape matches what the rendered form posts: string keys, string values,
  `reminder_config` as a list of `%{"value", "unit"}` maps and `custom_fields`
  as a list of definition maps. Custom fields and payment fields are omitted
  under exactly the same conditions as the hidden inputs (paywalled questions
  and hosts who cannot accept charges), so cast leaves those embeds untouched.
  """
  @spec build_params(map()) :: map()
  def build_params(assigns) do
    form_data = Map.get(assigns, :form_data) || %{}
    booking_limits = Map.get(assigns, :booking_limits) || %{}

    %{
      "name" => Map.get(form_data, "name", ""),
      "duration" => Map.get(form_data, "duration", ""),
      "description" => Map.get(form_data, "description", ""),
      "is_active" => active_param(Map.get(assigns, :type)),
      "meeting_mode" => assigns.meeting_mode,
      "video_integration_id" => to_param(assigns.selected_video_integration_id),
      "calendar_integration_id" => to_param(assigns.selected_calendar_integration_id),
      "target_calendar_id" => to_param(assigns.selected_target_calendar_id),
      "availability_schedule_id" =>
        to_param(Map.get(assigns, :selected_availability_schedule_id)),
      "icon" => assigns.selected_icon,
      "allow_guests" => to_string(Map.get(assigns, :allow_guests, false)),
      "requires_approval" => to_string(Map.get(assigns, :requires_approval, false)),
      "approval_window_hours" => to_param(Map.get(assigns, :approval_window_hours)),
      "show_as_free" => to_string(Map.get(assigns, :show_as_free, false)),
      "max_bookings_per_day" => to_param(booking_limits["max_bookings_per_day"]),
      "max_bookings_per_week" => to_param(booking_limits["max_bookings_per_week"]),
      "max_bookings_per_month" => to_param(booking_limits["max_bookings_per_month"]),
      "reminder_config" => Enum.map(assigns.reminders, &reminder_param/1)
    }
    |> maybe_put_custom_fields(assigns)
    |> maybe_put_payment(assigns)
  end

  @doc """
  Validates and persists `params`, creating or updating depending on
  `editing_type`.

  Returns `{:ok, meeting_type}` on success. Form-level validation failures are
  returned as `{:error, {:invalid_form, errors_map}}` so callers can route them
  to inline field errors; context-level failures surface as their original
  `{:error, atom}` / `{:error, changeset}` shapes.
  """
  @spec persist(map(), map(), Ecto.Schema.t() | nil, map()) ::
          {:ok, Ecto.Schema.t()}
          | {:error, {:invalid_form, map()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def persist(params, metadata, editing_type, current_user) do
    case InputValidation.validate_meeting_type_form(params, metadata: metadata) do
      {:ok, sanitized_params} ->
        ui_state = build_ui_state(params, sanitized_params)
        validated_params = SanitizeMerge.merge(params, sanitized_params)

        if editing_type do
          MeetingTypes.update_meeting_type_from_form(editing_type, validated_params, ui_state)
        else
          MeetingTypes.create_meeting_type_from_form(current_user.id, validated_params, ui_state)
        end

      {:error, validation_errors} ->
        {:error, {:invalid_form, validation_errors}}
    end
  end

  @doc """
  Builds the UI-state map the context uses to resolve mode, icon and the
  selected video integration from the submitted params.
  """
  @spec build_ui_state(map(), map()) :: map()
  def build_ui_state(params, sanitized_params) do
    %{
      meeting_mode: Map.get(sanitized_params, "meeting_mode", "personal"),
      selected_icon: Map.get(sanitized_params, "icon", "none"),
      selected_video_integration_id: parse_integer(Map.get(params, "video_integration_id"))
    }
  end

  defp active_param(%{is_active: is_active}), do: to_string(is_active)
  defp active_param(_type), do: "true"

  defp to_param(nil), do: ""
  defp to_param(value), do: to_string(value)

  defp reminder_param(%{value: value, unit: unit}),
    do: %{"value" => to_string(value), "unit" => unit}

  defp maybe_put_custom_fields(params, %{custom_questions_allowed: true, custom_fields: fields}),
    do: Map.put(params, "custom_fields", Enum.map(fields, &custom_field_param/1))

  defp maybe_put_custom_fields(params, _assigns), do: params

  defp custom_field_param(field) do
    %{
      "id" => field.id,
      "type" => field.type,
      "label" => field.label,
      "help_text" => field.help_text || "",
      "required" => to_string(field.required),
      "position" => to_string(field.position)
    }
    |> put_optional("body", field.body)
    |> put_optional("min", field.min)
    |> put_optional("max", field.max)
    |> maybe_put_options(field.options)
  end

  defp maybe_put_options(map, options) when is_list(options) and options != [] do
    Map.put(map, "options", Enum.map(options, &%{"key" => &1.key, "label" => &1.label}))
  end

  defp maybe_put_options(map, _options), do: map

  defp maybe_put_payment(
         params,
         %{payments_feature_enabled: true, payments_charges_enabled: true} = assigns
       ) do
    params
    |> Map.put("payment_required", to_string(assigns.payment_required))
    |> Map.put("price", assigns.payment_price)
  end

  defp maybe_put_payment(params, _assigns), do: params

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, to_string(value))

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil
  defp parse_integer(id) when is_integer(id), do: id

  defp parse_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _rest} -> int
      :error -> nil
    end
  end
end
