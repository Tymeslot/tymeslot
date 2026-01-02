defmodule Tymeslot.Onboarding do
  @moduledoc """
  Context module for onboarding business logic.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Profiles

  @steps [:welcome, :basic_settings, :scheduling_preferences, :complete]

  @doc """
  Returns the list of onboarding steps.
  """
  @spec get_steps() :: [atom()]
  def get_steps, do: @steps

  @doc """
  Determines the next step in the onboarding flow.
  """
  @spec next_step(atom()) :: {:ok, atom()} | {:complete, atom()} | {:error, :invalid_step}
  def next_step(:welcome), do: {:ok, :basic_settings}
  def next_step(:basic_settings), do: {:ok, :scheduling_preferences}
  def next_step(:scheduling_preferences), do: {:ok, :complete}
  def next_step(:complete), do: {:complete, :complete}
  def next_step(_), do: {:error, :invalid_step}

  @doc """
  Determines the previous step in the onboarding flow.
  """
  @spec previous_step(atom()) :: {:ok, atom()} | {:error, :first_step | :invalid_step}
  def previous_step(:basic_settings), do: {:ok, :welcome}
  def previous_step(:scheduling_preferences), do: {:ok, :basic_settings}
  def previous_step(:complete), do: {:ok, :scheduling_preferences}
  def previous_step(:welcome), do: {:error, :first_step}
  def previous_step(_), do: {:error, :invalid_step}

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
      timezone: "Europe/Kyiv",
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
      Auth.mark_onboarding_complete(user)
    end
  end

  @doc """
  Validates if a step is valid within the onboarding flow.
  """
  @spec valid_step?(atom() | String.t() | any()) :: boolean()
  def valid_step?(step) when is_atom(step) do
    step in @steps
  end

  def valid_step?(step) when is_binary(step) do
    step_atom = String.to_existing_atom(step)
    step_atom in @steps
  rescue
    ArgumentError -> false
  end

  def valid_step?(_), do: false
end
