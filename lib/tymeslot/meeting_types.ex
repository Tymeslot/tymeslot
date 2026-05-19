defmodule Tymeslot.MeetingTypes do
  @moduledoc """
  Context for managing meeting types.
  """
  alias Tymeslot.Features
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Utils.UriUtils
  require Logger

  @doc """
  Gets all active meeting types for a user, creating defaults if none exist.
  """
  @spec get_active_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_active_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user", user_id: user_id)
        create_default_meeting_types(user_id)
        MeetingTypeQueries.list_active_meeting_types(user_id)

      true ->
        MeetingTypeQueries.list_active_meeting_types(user_id)
    end
  end

  @doc """
  Gets all meeting types for a user (active and inactive).
  """
  @spec get_all_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_all_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user", user_id: user_id)
        create_default_meeting_types(user_id)
        MeetingTypeQueries.list_all_meeting_types(user_id)

      true ->
        MeetingTypeQueries.list_all_meeting_types(user_id)
    end
  end

  @doc """
  Gets a meeting type by ID and user ID.
  """
  @spec get_meeting_type(integer(), integer()) :: Ecto.Schema.t() | nil
  def get_meeting_type(id, user_id) do
    MeetingTypeQueries.get_meeting_type(id, user_id)
  end

  @doc """
  Creates a new meeting type.
  """
  @spec create_meeting_type(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_meeting_type(attrs) do
    MeetingTypeQueries.create_meeting_type(attrs)
  end

  @doc """
  Updates a meeting type.
  """
  @spec update_meeting_type(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update_meeting_type(meeting_type, attrs) do
    MeetingTypeQueries.update_meeting_type(meeting_type, attrs)
  end

  @doc """
  Toggles the active status of a meeting type without validating video integration.
  """
  @spec toggle_meeting_type_status(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def toggle_meeting_type_status(meeting_type, attrs) do
    MeetingTypeQueries.toggle_meeting_type_status(meeting_type, attrs)
  end

  @doc """
  Deletes a meeting type.
  """
  @spec delete_meeting_type(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete_meeting_type(meeting_type) do
    MeetingTypeQueries.delete_meeting_type(meeting_type)
  end

  @doc """
  Toggles the active status of a meeting type.
  """
  @spec toggle_meeting_type(integer(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def toggle_meeting_type(id, user_id) do
    case get_meeting_type(id, user_id) do
      nil ->
        {:error, :not_found}

      meeting_type ->
        update_meeting_type(meeting_type, %{is_active: !meeting_type.is_active})
    end
  end

  @doc """
  Reorders meeting types for a user.
  """
  @spec reorder_meeting_types(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_meeting_types(user_id, meeting_type_ids) when is_list(meeting_type_ids) do
    MeetingTypeQueries.reorder_meeting_types(user_id, meeting_type_ids)
  end

  @doc """
  Finds a meeting type by its slug (derived from name).
  """
  @spec find_by_slug(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_slug(user_id, slug) do
    Enum.find(get_active_meeting_types(user_id), fn mt ->
      to_slug(mt) == slug
    end)
  end

  @doc """
  Converts meeting type to slug format used in URLs.
  """
  @spec to_slug(Ecto.Schema.t()) :: String.t()
  def to_slug(meeting_type) do
    meeting_type.name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Converts meeting type to duration string format used in URLs.
  """
  @spec to_duration_string(Ecto.Schema.t()) :: String.t()
  def to_duration_string(meeting_type) do
    to_slug(meeting_type)
  end

  @doc """
  Normalizes duration inputs into the slug format used in URLs.
  """
  @spec normalize_duration_slug(String.t() | nil) :: String.t() | nil
  def normalize_duration_slug(nil), do: nil

  def normalize_duration_slug(duration) when is_binary(duration) do
    case Regex.run(~r/^(\d+)min$/, duration) do
      [_match, minutes] -> "#{minutes}-minutes"
      _no_match -> duration
    end
  end

  @doc """
  Finds a meeting type by duration string (now deprecated in favor of find_by_slug).
  """
  @spec find_by_duration_string(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_duration_string(user_id, slug) do
    find_by_slug(user_id, slug)
  end

  @doc """
  Validates that a duration has been selected from available meeting types.
  Used in booking workflow validation.
  """
  @spec validate_duration_selection(String.t() | nil, [Ecto.Schema.t()]) ::
          :ok | {:error, String.t()}
  def validate_duration_selection(nil, _available_types),
    do: {:error, "Please select a meeting duration"}

  def validate_duration_selection("", _available_types),
    do: {:error, "Please select a meeting duration"}

  def validate_duration_selection(duration, available_types) when is_list(available_types) do
    if duration_valid?(duration, available_types) do
      :ok
    else
      {:error, "Invalid meeting duration selected"}
    end
  end

  def validate_duration_selection(_duration, _available_types),
    do: {:error, "Please select a meeting duration"}

  @doc """
  Checks if a duration is valid against available meeting types.
  """
  @spec duration_valid?(any(), any()) :: boolean()
  def duration_valid?(duration, available_types)
      when is_binary(duration) and is_list(available_types) do
    Enum.any?(available_types, fn meeting_type ->
      to_duration_string(meeting_type) == duration
    end)
  end

  def duration_valid?(_duration, _available_types), do: false

  @doc """
  Lists all meeting types for a user.
  """
  @spec list_meeting_types(integer()) :: [Ecto.Schema.t()]
  def list_meeting_types(user_id) do
    get_all_meeting_types(user_id)
  end

  @doc """
  Gets a meeting type by ID, raising if not found.
  """
  @spec get_meeting_type!(integer()) :: Ecto.Schema.t()
  def get_meeting_type!(id) do
    MeetingTypeQueries.get_meeting_type!(id)
  end

  @doc """
  Creates a meeting type from form parameters with validation.
  """
  @spec create_meeting_type_from_form(integer(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_meeting_type_from_form(user_id, form_params, ui_state) do
    with {:ok, attrs} <- build_meeting_type_attrs(form_params, ui_state),
         :ok <- gate_custom_fields_change(user_id, attrs),
         :ok <- validate_video_integration(attrs, user_id),
         :ok <- validate_calendar_integration(attrs, user_id) do
      create_meeting_type(Map.put(attrs, :user_id, user_id))
    end
  end

  @doc """
  Updates a meeting type from form parameters with validation.
  """
  @spec update_meeting_type_from_form(Ecto.Schema.t(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_meeting_type_from_form(meeting_type, form_params, ui_state) do
    with {:ok, attrs} <- build_meeting_type_attrs(form_params, ui_state),
         :ok <- gate_custom_fields_change(meeting_type.user_id, attrs),
         :ok <- validate_video_integration(attrs, meeting_type.user_id),
         :ok <- validate_calendar_integration(attrs, meeting_type.user_id) do
      update_meeting_type(meeting_type, attrs)
    end
  end

  @doc """
  Creates default meeting types for a new user.
  Fetches the user's primary calendar integration, builds default templates,
  deduplicates against existing names, then bulk-inserts.
  """
  @spec create_default_meeting_types(integer()) ::
          {:ok, [MeetingTypeSchema.t()]} | {:error, term()}
  def create_default_meeting_types(user_id) when is_integer(user_id) do
    {calendar_integration_id, target_calendar_id} = resolve_primary_calendar(user_id)
    existing = MeetingTypeQueries.existing_names(user_id)
    now = NaiveDateTime.utc_now(:second)

    user_id
    |> default_meeting_type_templates(calendar_integration_id, target_calendar_id, now)
    |> Enum.reject(fn type -> MapSet.member?(existing, type.name) end)
    |> MeetingTypeQueries.bulk_insert_meeting_types()
  end

  @spec create_default_meeting_types(term()) :: {:error, :invalid_user_id}
  def create_default_meeting_types(_invalid_user_id), do: {:error, :invalid_user_id}

  # Private functions

  defp resolve_primary_calendar(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, %{default_booking_calendar_id: cal_id} = integration}
      when is_binary(cal_id) ->
        {integration.id, cal_id}

      _other ->
        {nil, nil}
    end
  end

  defp default_meeting_type_templates(
         user_id,
         calendar_integration_id,
         target_calendar_id,
         now
       ) do
    [
      %{
        user_id: user_id,
        name: "15 Minutes",
        description: "Quick chat or brief consultation",
        duration_minutes: 15,
        icon: "hero-bolt",
        sort_order: 0,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      },
      %{
        user_id: user_id,
        name: "30 Minutes",
        description: "In-depth discussion or detailed review",
        duration_minutes: 30,
        icon: "hero-rocket-launch",
        sort_order: 1,
        is_active: true,
        allow_video: false,
        calendar_integration_id: calendar_integration_id,
        target_calendar_id: target_calendar_id,
        reminder_config: [%{value: 30, unit: "minutes"}],
        inserted_at: now,
        updated_at: now
      }
    ]
  end

  defp build_meeting_type_attrs(params, ui_state) do
    video_integration_id =
      if ui_state.meeting_mode == "video" do
        ui_state.selected_video_integration_id
      else
        nil
      end

    with {:ok, reminder_config} <- normalize_reminder_config_params(params["reminder_config"]) do
      attrs = %{
        name: params["name"],
        duration_minutes: String.to_integer(params["duration"]),
        description: params["description"],
        icon: ui_state.selected_icon,
        is_active: params["is_active"] == "true",
        allow_video: ui_state.meeting_mode == "video",
        video_integration_id: video_integration_id,
        calendar_integration_id: blank_to_nil(params["calendar_integration_id"]),
        target_calendar_id: blank_to_nil(params["target_calendar_id"]),
        reminder_config: reminder_config
      }

      attrs =
        if Map.has_key?(params, "custom_fields") do
          Map.put(attrs, :custom_fields, params["custom_fields"])
        else
          attrs
        end

      {:ok, attrs}
    end
  rescue
    ArgumentError ->
      {:error, :invalid_duration}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Custom booking questions are gated behind the :custom_questions_allowed
  # feature flag. Core's default checker always allows access, so self-hosted
  # deployments are unaffected; SaaS overrides this to require a Pro plan.
  # Only writes that would add or modify a non-empty question list are gated —
  # an absent or empty list (the no-questions path) is always allowed.
  defp gate_custom_fields_change(user_id, attrs) do
    case Map.get(attrs, :custom_fields) do
      nil -> :ok
      fields when fields == [] or fields == %{} -> :ok
      _non_empty -> Features.check_access(user_id, :custom_questions_allowed)
    end
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: nil}, _user_id) do
    {:error, :video_integration_required}
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: ""}, _user_id),
    do: {:error, :video_integration_required}

  defp validate_video_integration(%{allow_video: true, video_integration_id: id}, user_id)
       when is_integer(id) do
    case Video.fetch_integration_for_user(id, user_id) do
      {:ok, %{is_active: true}} -> :ok
      {:ok, _integration} -> {:error, :invalid_video_integration}
      {:error, :not_found} -> {:error, :invalid_video_integration}
    end
  end

  defp validate_video_integration(_attrs, _user_id), do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: nil, target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: nil},
         _user_id
       ),
       do: :ok

  defp validate_calendar_integration(%{calendar_integration_id: nil}, _user_id),
    do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: "", target_calendar_id: _target},
         _user_id
       ),
       do: {:error, :calendar_integration_required}

  defp validate_calendar_integration(
         %{calendar_integration_id: id, target_calendar_id: target_calendar_id},
         user_id
       )
       when is_integer(id) do
    with {:ok, integration} <- CalendarManagement.fetch_integration_for_user(id, user_id),
         :ok <- validate_target_calendar(target_calendar_id, integration) do
      :ok
    else
      {:error, :not_found} -> {:error, :calendar_integration_invalid}
      {:error, _reason} = error -> error
    end
  end

  defp validate_calendar_integration(%{calendar_integration_id: id}, _user_id)
       when is_binary(id) and id != "" do
    {:error, :calendar_integration_invalid}
  end

  defp validate_calendar_integration(_other_attrs, _user_id), do: :ok

  defp validate_target_calendar(nil, _calendar_integration),
    do: {:error, :target_calendar_required}

  defp validate_target_calendar("", _calendar_integration),
    do: {:error, :target_calendar_required}

  defp validate_target_calendar(target_calendar_id, integration) do
    calendar_list = integration.calendar_list

    if calendar_list == [] do
      :ok
    else
      found? =
        Enum.any?(calendar_list, fn cal ->
          UriUtils.uri_safe_match?(cal["id"] || cal[:id], target_calendar_id)
        end)

      if found? do
        :ok
      else
        {:error, :target_calendar_invalid}
      end
    end
  end

  defp normalize_reminder_config_params(nil), do: {:ok, nil}
  defp normalize_reminder_config_params(""), do: {:ok, nil}

  defp normalize_reminder_config_params(reminders) when is_list(reminders) do
    normalized = Enum.map(reminders, &ReminderUtils.normalize_reminder_string_keys/1)

    if Enum.any?(normalized, &match?({:error, _error_reason}, &1)) do
      {:error, :invalid_reminder_config}
    else
      {:ok, Enum.map(normalized, fn {:ok, reminder} -> reminder end)}
    end
  end

  defp normalize_reminder_config_params(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> normalize_reminder_config_params()
  end

  defp normalize_reminder_config_params(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> normalize_reminder_config_params(decoded)
      {:error, _decode_error} -> {:error, :invalid_reminder_config}
    end
  end

  defp normalize_reminder_config_params(_other), do: {:error, :invalid_reminder_config}
end
