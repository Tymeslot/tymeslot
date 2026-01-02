defmodule Tymeslot.Demo.Integrations do
  @moduledoc """
  Demo implementation of integrations functionality.

  This module provides integration operations for demo users,
  returning hardcoded data instead of querying the database.
  """

  alias Tymeslot.Demo.Data

  @doc """
  Lists calendar integrations for a demo user (always empty).
  """
  @spec list_calendar_integrations(integer()) :: []
  def list_calendar_integrations(user_id) when is_integer(user_id) do
    Data.get_demo_calendar_integrations(user_id)
  end

  @doc """
  Gets video integration for a demo user.
  """
  @spec get_video_integration(integer()) :: map() | nil
  def get_video_integration(integration_id) when is_integer(integration_id) do
    Data.get_demo_video_integration(integration_id)
  end

  @doc """
  Gets active video integration for a demo user.
  """
  @spec get_active_video_integration(integer()) :: map() | nil
  def get_active_video_integration(user_id) when is_integer(user_id) do
    Data.get_demo_video_integration(user_id)
  end

  @doc """
  Lists video integrations for a demo user.
  """
  @spec list_video_integrations(integer()) :: [map()]
  def list_video_integrations(user_id) when is_integer(user_id) do
    case Data.get_demo_video_integration(user_id) do
      nil -> []
      integration -> [integration]
    end
  end

  @doc """
  Creates calendar integration (no-op for demo mode).
  """
  @spec create_calendar_integration(any(), any()) :: {:error, :demo_mode}
  def create_calendar_integration(_user, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Creates video integration (no-op for demo mode).
  """
  @spec create_video_integration(any(), any()) :: {:error, :demo_mode}
  def create_video_integration(_user, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Updates integration (no-op for demo mode).
  """
  @spec update_integration(any(), any()) :: {:error, :demo_mode}
  def update_integration(_integration, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Deletes integration (no-op for demo mode).
  """
  @spec delete_integration(any()) :: {:error, :demo_mode}
  def delete_integration(_integration) do
    {:error, :demo_mode}
  end
end
