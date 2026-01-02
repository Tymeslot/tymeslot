defmodule Tymeslot.Demo.MeetingTypes do
  @moduledoc """
  Demo implementation of meeting types functionality.

  This module provides meeting type operations for demo users,
  returning hardcoded data instead of querying the database.
  """

  alias Tymeslot.Demo.Data

  @doc """
  Lists active meeting types for a demo user.
  """
  @spec list_active_meeting_types(integer()) :: [map()]
  def list_active_meeting_types(user_id) when is_integer(user_id) do
    Data.get_demo_meeting_types(user_id)
  end

  @doc """
  Gets a specific meeting type by ID.
  """
  @spec get_meeting_type(integer()) :: map() | nil
  def get_meeting_type(meeting_type_id) when is_integer(meeting_type_id) do
    # Find the meeting type across all demo users
    all_types =
      Data.get_demo_meeting_types(999_001) ++
        Data.get_demo_meeting_types(999_002)

    Enum.find(all_types, fn type -> type.id == meeting_type_id end)
  end

  @doc """
  Creates a meeting type (no-op for demo mode).
  """
  @spec create_meeting_type(any(), any()) :: {:error, :demo_mode}
  def create_meeting_type(_user, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Updates a meeting type (no-op for demo mode).
  """
  @spec update_meeting_type(any(), any()) :: {:error, :demo_mode}
  def update_meeting_type(_meeting_type, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Deletes a meeting type (no-op for demo mode).
  """
  @spec delete_meeting_type(any()) :: {:error, :demo_mode}
  def delete_meeting_type(_meeting_type) do
    {:error, :demo_mode}
  end

  @doc """
  Finds a meeting type by duration string for a demo user.
  """
  @spec find_by_duration_string(integer(), String.t()) :: map() | nil
  def find_by_duration_string(user_id, duration_string)
      when is_integer(user_id) and is_binary(duration_string) do
    meeting_types = Data.get_demo_meeting_types(user_id)

    Enum.find(meeting_types, fn meeting_type ->
      "#{meeting_type.duration_minutes}min" == duration_string
    end)
  end
end
