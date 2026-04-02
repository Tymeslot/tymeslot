defmodule Tymeslot.DatabaseQueries.CalendarPreferencesQueries do
  @moduledoc false

  alias Tymeslot.DatabaseSchemas.CalendarPreferencesSchema
  alias Tymeslot.Repo

  @updatable_fields [
    :default_view,
    :hidden_integration_ids,
    :week_start_day,
    :time_format,
    :show_week_numbers,
    :show_weekends,
    :updated_at
  ]

  @doc "Returns preferences for user, or a new empty struct if none exist."
  @spec get_or_create(integer()) :: CalendarPreferencesSchema.t()
  def get_or_create(user_id) do
    case Repo.get_by(CalendarPreferencesSchema, user_id: user_id) do
      nil -> %CalendarPreferencesSchema{user_id: user_id}
      prefs -> prefs
    end
  end

  @doc "Upserts preferences for user. Creates if not present, updates if present."
  @spec upsert(integer(), map()) ::
          {:ok, CalendarPreferencesSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert(user_id, attrs) do
    %CalendarPreferencesSchema{user_id: user_id}
    |> CalendarPreferencesSchema.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert(
      on_conflict: {:replace, @updatable_fields},
      conflict_target: :user_id
    )
  end
end
