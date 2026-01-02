defmodule Tymeslot.Demo.Availability do
  @moduledoc """
  Demo implementation of availability functionality.

  This module provides availability operations for demo users,
  returning hardcoded data instead of querying the database.
  """

  alias Tymeslot.Demo.Data

  @doc """
  Gets weekly schedule for a demo profile.
  """
  @spec get_weekly_schedule(integer()) :: any
  def get_weekly_schedule(profile_id) when is_integer(profile_id) do
    Data.get_demo_weekly_availability(profile_id)
  end

  @doc """
  Lists availability breaks for a demo profile (always empty).
  """
  @spec list_availability_breaks(integer()) :: list(map())
  def list_availability_breaks(profile_id) when is_integer(profile_id) do
    Data.get_demo_availability_breaks(profile_id)
  end

  @doc """
  Lists availability overrides for a demo profile (always empty).
  """
  @spec list_availability_overrides(integer()) :: list(map())
  def list_availability_overrides(profile_id) when is_integer(profile_id) do
    Data.get_demo_availability_overrides(profile_id)
  end

  @doc """
  Updates weekly schedule (no-op for demo mode).
  """
  @spec update_weekly_schedule(any(), any()) :: {:error, :demo_mode}
  def update_weekly_schedule(_profile, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Creates availability break (no-op for demo mode).
  """
  @spec create_availability_break(any(), any()) :: {:error, :demo_mode}
  def create_availability_break(_profile, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Creates availability override (no-op for demo mode).
  """
  @spec create_availability_override(any(), any()) :: {:error, :demo_mode}
  def create_availability_override(_profile, _attrs) do
    {:error, :demo_mode}
  end
end
