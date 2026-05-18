defmodule Tymeslot.AppSettings.AppSettingsQueries do
  @moduledoc """
  Query interface for the singleton `app_settings` row.
  """

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.AppSettings.AppSettingsSchema
  alias Tymeslot.Repo

  @singleton_id 1

  @doc """
  Returns the singleton settings row. The row is seeded by the migration, so
  this always returns a struct — never `nil` — except during the brief window
  before the migration has run, in which case it falls back to a struct with
  all overrides set to `nil` (i.e. "no overrides, use config defaults").
  """
  @spec get_settings(module()) :: AppSettingsSchema.t()
  def get_settings(repo \\ Repo) do
    repo.get(AppSettingsSchema, @singleton_id) || %AppSettingsSchema{id: @singleton_id}
  rescue
    # Table may not exist yet on pre-migration boot; settle for an empty struct.
    DBConnection.ConnectionError -> %AppSettingsSchema{id: @singleton_id}
    Postgrex.Error -> %AppSettingsSchema{id: @singleton_id}
  end

  @doc """
  Updates the singleton settings row with the given attributes.

  The read and write are wrapped in a serialisable transaction with a
  `FOR UPDATE` row lock, preventing two concurrent admin saves from
  overwriting each other's changes.
  """
  @spec update_settings(map(), module()) ::
          {:ok, AppSettingsSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs, repo \\ Repo) when is_map(attrs) do
    repo.transaction(fn ->
      query = from(s in AppSettingsSchema, where: s.id == @singleton_id, lock: "FOR UPDATE")
      settings = repo.one(query) || %AppSettingsSchema{id: @singleton_id}

      case settings |> AppSettingsSchema.changeset(attrs) |> repo.insert_or_update() do
        {:ok, updated} -> updated
        {:error, changeset} -> repo.rollback(changeset)
      end
    end)
  end
end
