defmodule Tymeslot.Integrations.Calendar.Preferences do
  @moduledoc """
  A user's calendar display preferences: the stored row (or its defaults) and
  the week start it carries.

  `Tymeslot.Integrations.Calendar.Management` delegates to this module for its
  existing callers.
  """

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Locales.WeekStart

  @type user_id :: integer()

  @doc """
  The user's calendar display preferences. Returns the stored row if one
  exists, otherwise an unsaved struct populated with defaults — callers that
  need the defaults persisted must call `save_preferences/2` themselves.
  """
  @spec get_or_create_preferences(user_id()) :: struct()
  def get_or_create_preferences(user_id) do
    CalendarPreferencesQueries.get_or_create(user_id)
  end

  @doc """
  The day the user's week starts on, as set in their calendar settings:
  `:monday` unless they chose Sunday.

  Governs their weekly booking caps, and is their booking page's fallback
  when a visitor's language does not settle it.
  """
  @spec get_week_start(user_id() | nil) :: WeekStart.t()
  def get_week_start(nil), do: :monday

  def get_week_start(user_id) do
    user_id
    |> CalendarPreferencesQueries.get_or_create()
    |> Map.get(:week_start_day)
    |> WeekStart.parse()
  end

  @doc """
  Upserts the user's calendar display preferences.
  """
  @spec save_preferences(user_id(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    CalendarPreferencesQueries.upsert(user_id, attrs)
  end
end
