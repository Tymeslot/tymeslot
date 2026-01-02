defmodule Tymeslot.Profiles.Settings do
  @moduledoc """
  Context module for profile settings updates during onboarding and beyond.
  """

  alias Tymeslot.Profiles

  @doc """
  Updates basic profile settings (name, username, timezone) with input validation.

  Note: Input should be pre-validated with OnboardingInputProcessor before calling this function.

  Options:
  - `dev_mode`: boolean - if true, returns updated profile map without database persistence
  """
  @spec update_basic_settings(term(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def update_basic_settings(profile, params, opts \\ []) do
    dev_mode = Keyword.get(opts, :dev_mode, false)

    # Extract the form fields, providing defaults if not present
    full_name = Map.get(params, "full_name", profile.full_name || "")
    username = Map.get(params, "username", profile.username || "")
    timezone = Map.get(params, "timezone", profile.timezone || "UTC")

    # Skip update if this is just a timezone search event (contains "value" key)
    if Map.has_key?(params, "value") do
      {:ok, profile}
    else
      if dev_mode do
        updated_profile =
          Map.merge(profile, %{
            full_name: full_name,
            username: username,
            timezone: timezone
          })

        {:ok, updated_profile}
      else
        attrs = %{
          full_name: full_name,
          username: username,
          timezone: timezone
        }

        Profiles.update_profile(profile, attrs)
      end
    end
  end

  @doc """
  Updates scheduling preferences (buffer time, booking window, advance notice) with input validation.

  Note: Input should be pre-validated with OnboardingInputProcessor before calling this function.

  Options:
  - `dev_mode`: boolean - if true, returns updated profile map without database persistence
  """
  @spec update_scheduling_preferences(term(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def update_scheduling_preferences(profile, params, opts \\ []) do
    dev_mode = Keyword.get(opts, :dev_mode, false)

    # Extract the specific value that was clicked
    {field, value} =
      cond do
        Map.has_key?(params, "buffer_minutes") ->
          {:buffer_minutes, String.to_integer(params["buffer_minutes"])}

        Map.has_key?(params, "advance_booking_days") ->
          {:advance_booking_days, String.to_integer(params["advance_booking_days"])}

        Map.has_key?(params, "min_advance_hours") ->
          {:min_advance_hours, String.to_integer(params["min_advance_hours"])}

        true ->
          {nil, nil}
      end

    if field do
      if dev_mode do
        updated_profile = Map.put(profile, field, value)
        {:ok, updated_profile}
      else
        attrs = %{field => value}
        Profiles.update_profile(profile, attrs)
      end
    else
      {:ok, profile}
    end
  end

  @doc """
  Updates profile timezone with input validation.

  Note: Input should be pre-validated with OnboardingInputProcessor before calling this function.

  Options:
  - `dev_mode`: boolean - if true, returns updated profile map without database persistence
  """
  @spec update_timezone(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def update_timezone(profile, timezone, opts \\ []) do
    dev_mode = Keyword.get(opts, :dev_mode, false)

    if dev_mode do
      updated_profile = Map.put(profile, :timezone, timezone)
      {:ok, updated_profile}
    else
      Profiles.update_timezone(profile, timezone)
    end
  end
end
