defmodule Tymeslot.MeetingTypes.Duration do
  @moduledoc """
  Duration parsing, normalisation, and validation for meeting types.

  A meeting type's duration drives both its URL slug (`30min` → `30-minutes`)
  and the booking-flow guard that a chosen duration matches one the host
  actually offers. This module owns those rules; the context delegates to it.
  """

  alias Tymeslot.MeetingTypes.Slugs

  @doc """
  Normalizes duration inputs into the slug format used in URLs.
  """
  @spec normalize_duration_slug(String.t() | nil) :: String.t() | nil
  def normalize_duration_slug(nil), do: nil

  def normalize_duration_slug(duration) when is_binary(duration) do
    case Regex.run(~r/^(\d+)min$/, duration) do
      [_match, minutes] -> "#{minutes}-minutes"
      _no_match -> duration
    end
  end

  @doc """
  Finds a meeting type by duration string (now deprecated in favor of find_by_slug).
  """
  @spec find_by_duration_string(integer(), String.t()) :: Ecto.Schema.t() | nil
  def find_by_duration_string(user_id, slug) do
    Slugs.find_by_slug(user_id, slug)
  end

  @typedoc "Why a duration selection is not yet good enough to advance on."
  @type selection_error :: :duration_required | :duration_invalid

  @doc """
  Validates that a duration has been selected from available meeting types.
  Used in booking workflow validation.

  Returns a reason atom rather than copy: this is a public, multi-locale
  booking page, and rendering an atom to user-facing text is the web layer's
  responsibility (the same split `Tymeslot.Bookings.Errors` states).
  """
  @spec validate_duration_selection(String.t() | nil, [Ecto.Schema.t()]) ::
          :ok | {:error, selection_error()}
  def validate_duration_selection(nil, _available_types), do: {:error, :duration_required}

  def validate_duration_selection("", _available_types), do: {:error, :duration_required}

  def validate_duration_selection(duration, available_types) when is_list(available_types) do
    if duration_valid?(duration, available_types) do
      :ok
    else
      {:error, :duration_invalid}
    end
  end

  def validate_duration_selection(_duration, _available_types), do: {:error, :duration_required}

  @doc """
  Checks if a duration is valid against available meeting types.
  """
  @spec duration_valid?(any(), any()) :: boolean()
  def duration_valid?(duration, available_types)
      when is_binary(duration) and is_list(available_types) do
    Enum.any?(available_types, fn meeting_type ->
      Slugs.to_duration_string(meeting_type) == duration
    end)
  end

  def duration_valid?(_duration, _available_types), do: false
end
