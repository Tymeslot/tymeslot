defmodule Tymeslot.Demo.ThemeCustomizations do
  @moduledoc """
  Demo implementation of theme customizations.

  This module provides theme customization operations for demo users,
  returning hardcoded data instead of querying the database.
  """

  alias Tymeslot.Demo.Data

  @doc """
  Gets theme customization by profile and theme.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: map() | nil
  def get_by_profile_and_theme(profile_id, theme_id)
      when is_integer(profile_id) and is_binary(theme_id) do
    profile =
      case profile_id do
        999_001 -> Data.get_demo_profile("1")
        999_002 -> Data.get_demo_profile("2")
        _ -> nil
      end

    case profile do
      nil ->
        nil

      profile ->
        if profile.theme_customization.theme_id == theme_id do
          profile.theme_customization
        else
          nil
        end
    end
  end

  @doc """
  Creates or updates theme customization (no-op for demo mode).
  """
  @spec create_or_update(any, String.t(), map()) :: {:error, :demo_mode}
  def create_or_update(_profile, _theme_id, _attrs) do
    {:error, :demo_mode}
  end

  @doc """
  Deletes theme customization (no-op for demo mode).
  """
  @spec delete_customization(integer(), String.t()) :: {:error, :demo_mode}
  def delete_customization(_profile_id, _theme_id) do
    {:error, :demo_mode}
  end
end
