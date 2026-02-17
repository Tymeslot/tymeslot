defmodule Tymeslot.Profiles.Scheduling do
  @moduledoc """
  Subcomponent for managing profile scheduling preferences.
  Focuses on validation and coordination with ProfileQueries.
  """

  alias Tymeslot.Bookings.Validation
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema

  @type profile :: ProfileSchema.t()
  @type result(t) :: {:ok, t} | {:error, any()}

  @doc """
  Updates buffer minutes with validation.
  """
  @spec update_buffer_minutes(profile, String.t() | integer()) :: result(profile)
  def update_buffer_minutes(%ProfileSchema{} = profile, buffer_str) when is_binary(buffer_str) do
    case Integer.parse(buffer_str) do
      {buffer_minutes, _value} -> update_buffer_minutes(profile, buffer_minutes)
      _other -> {:error, :invalid_buffer_minutes}
    end
  end

  def update_buffer_minutes(%ProfileSchema{} = profile, buffer_minutes)
      when is_integer(buffer_minutes) do
    if Validation.valid_buffer_minutes?(buffer_minutes) do
      ProfileQueries.update_profile(profile, %{buffer_minutes: buffer_minutes})
    else
      {:error, :invalid_buffer_minutes}
    end
  end

  @doc """
  Updates advance booking days with validation.
  """
  @spec update_advance_booking_days(profile, String.t() | integer()) :: result(profile)
  def update_advance_booking_days(%ProfileSchema{} = profile, days_str)
      when is_binary(days_str) do
    case Integer.parse(days_str) do
      {days, _value} -> update_advance_booking_days(profile, days)
      _other -> {:error, :invalid_advance_booking_days}
    end
  end

  def update_advance_booking_days(%ProfileSchema{} = profile, days) when is_integer(days) do
    if Validation.valid_booking_window?(days) do
      ProfileQueries.update_profile(profile, %{advance_booking_days: days})
    else
      {:error, :invalid_advance_booking_days}
    end
  end

  @doc """
  Updates minimum advance hours with validation.
  """
  @spec update_min_advance_hours(profile, String.t() | integer()) :: result(profile)
  def update_min_advance_hours(%ProfileSchema{} = profile, hours_str) when is_binary(hours_str) do
    case Integer.parse(hours_str) do
      {hours, _value} when hours >= 0 and hours <= 168 ->
        ProfileQueries.update_profile(profile, %{min_advance_hours: hours})

      _other ->
        {:error, :invalid_min_advance_hours}
    end
  end

  def update_min_advance_hours(%ProfileSchema{} = profile, hours) when is_integer(hours) do
    if hours >= 0 and hours <= 168 do
      ProfileQueries.update_profile(profile, %{min_advance_hours: hours})
    else
      {:error, :invalid_min_advance_hours}
    end
  end
end
