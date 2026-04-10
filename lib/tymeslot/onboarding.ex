defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Profiles

  @doc """
  Creates a mock profile for development mode.
  """
  @spec create_dev_profile() :: map()
  def create_dev_profile do
    %{
      id: 1,
      user_id: 1,
      username: nil,
      full_name: nil,
      timezone: Profiles.get_default_timezone(),
      buffer_minutes: 15,
      advance_booking_days: 90,
      min_advance_hours: 3,
      avatar: nil,
      booking_theme: "1"
    }
  end

  @doc """
  Creates a mock user for development mode.
  """
  @spec create_dev_user() :: map()
  def create_dev_user do
    %{
      id: 1,
      email: "dev@example.com",
      name: "Development User",
      onboarding_completed_at: nil
    }
  end

  @doc """
  Gets or creates a profile for the given user, handling both dev and production modes.
  """
  @spec get_or_create_profile(integer(), boolean()) ::
          {:ok, Ecto.Schema.t() | map()} | {:error, any()}
  def get_or_create_profile(user_id, dev_mode \\ false) do
    if dev_mode do
      {:ok, create_dev_profile()}
    else
      Profiles.get_or_create_profile(user_id)
    end
  end

  @doc """
  Completes the onboarding process for a user.
  """
  @spec complete_onboarding(Ecto.Schema.t() | map(), boolean()) ::
          {:ok, Ecto.Schema.t() | map()} | {:error, any()}
  def complete_onboarding(user, dev_mode \\ false) do
    if dev_mode do
      {:ok, user}
    else
      Profiles.mark_onboarding_complete(user)
    end
  end
end
