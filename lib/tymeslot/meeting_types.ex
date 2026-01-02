defmodule Tymeslot.MeetingTypes do
  @moduledoc """
  Context for managing meeting types.
  """
  alias Tymeslot.DatabaseQueries.MeetingTypeQueries
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  require Logger

  @doc """
  Gets all active meeting types for a user, creating defaults if none exist.
  """
  @spec get_active_meeting_types(integer()) :: [Ecto.Schema.t()]
  def get_active_meeting_types(user_id) do
    case MeetingTypeQueries.has_meeting_types?(user_id) do
      false ->
        Logger.info("Creating default meeting types for user #{user_id}")
        MeetingTypeQueries.create_default_meeting_types(user_id)
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
        Logger.info("Creating default meeting types for user #{user_id}")
        MeetingTypeQueries.create_default_meeting_types(user_id)
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
  Converts meeting type to duration string format used in URLs.
  """
  @spec to_duration_string(Ecto.Schema.t()) :: String.t()
  def to_duration_string(meeting_type) do
    "#{meeting_type.duration_minutes}min"
  end

  @doc """
  Finds a meeting type by duration string.
  """
  @spec find_by_duration_string(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_duration_string(user_id, duration_string) do
    duration_minutes =
      case Regex.run(~r/^(\d+)min$/, duration_string) do
        [_, minutes] -> String.to_integer(minutes)
        _ -> nil
      end

    if duration_minutes do
      Enum.find(get_active_meeting_types(user_id), &(&1.duration_minutes == duration_minutes))
    else
      nil
    end
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
         :ok <- validate_video_integration(attrs, user_id) do
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
         :ok <- validate_video_integration(attrs, meeting_type.user_id) do
      update_meeting_type(meeting_type, attrs)
    end
  end

  # Private functions

  defp build_meeting_type_attrs(params, ui_state) do
    video_integration_id =
      if ui_state.meeting_mode == "video" do
        ui_state.selected_video_integration_id
      else
        nil
      end

    attrs = %{
      name: params["name"],
      duration_minutes: String.to_integer(params["duration"]),
      description: params["description"],
      icon: ui_state.selected_icon,
      is_active: params["is_active"] == "true",
      allow_video: ui_state.meeting_mode == "video",
      video_integration_id: video_integration_id
    }

    {:ok, attrs}
  rescue
    ArgumentError ->
      {:error, :invalid_duration}
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: nil}, _user_id) do
    {:error, :video_integration_required}
  end

  defp validate_video_integration(%{allow_video: true, video_integration_id: ""}, _user_id),
    do: {:error, :video_integration_required}

  defp validate_video_integration(%{allow_video: true, video_integration_id: id}, user_id)
       when is_integer(id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, %{is_active: true}} -> :ok
      {:ok, _inactive} -> {:error, :invalid_video_integration}
      {:error, :not_found} -> {:error, :invalid_video_integration}
    end
  end

  defp validate_video_integration(_attrs, _user_id), do: :ok
end
