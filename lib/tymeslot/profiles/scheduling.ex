defmodule Tymeslot.Profiles.Scheduling do
  @moduledoc """
  Subcomponent for managing a profile's account-wide booking limits.

  Buffer, minimum notice and the advance booking window are no longer profile
  settings: they belong to an availability schedule and are edited through
  `Tymeslot.Availability.Schedules.update_policy/2`.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  @booking_limit_fields Constraints.booking_limit_fields()

  @type profile :: ProfileSchema.t()
  @type result(t) :: {:ok, t} | {:error, any()}

  @doc """
  Updates one account-wide booking-limit field with validation.

  `nil` or a blank string clears the limit (no limit); integers and numeric
  strings must fall within `Constraints.booking_limit_range/0`.
  """
  @spec update_booking_limit(profile, atom(), String.t() | integer() | nil) :: result(profile)
  def update_booking_limit(%ProfileSchema{} = profile, field, value)
      when field in @booking_limit_fields do
    case parse_booking_limit(value) do
      {:ok, limit} ->
        profile |> ProfileQueries.update_booking_limits(%{field => limit}) |> changed()

      :error ->
        {:error, :invalid_booking_limit}
    end
  end

  # The booking page hides a slot whose day, week or month is at the cap.
  defp changed({:ok, profile} = result) do
    Availability.changed(profile)
    result
  end

  defp changed(error), do: error

  defp parse_booking_limit(nil), do: {:ok, nil}

  defp parse_booking_limit(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {limit, ""} -> parse_booking_limit(limit)
          _other -> :error
        end
    end
  end

  defp parse_booking_limit(value) when is_integer(value) do
    if value in Constraints.booking_limit_range() do
      {:ok, value}
    else
      :error
    end
  end
end
