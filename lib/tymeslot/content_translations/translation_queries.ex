defmodule Tymeslot.ContentTranslations.TranslationQueries do
  @moduledoc """
  Writes a record's `translations` column, for every translated table
  (`profiles`, `booking_pages`, `meeting_types`, `venues`). The changeset is
  `Tymeslot.ContentTranslations.changeset/2`, which casts that column alone.
  """

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.Repo

  @doc """
  `record` with its `translations` as they stand now, its row locked
  `FOR UPDATE` until the surrounding transaction ends, so a save built on
  them cannot overwrite another committed in the meantime. Only the
  translations are re-read; the rest of `record` is the caller's.
  """
  @spec lock(struct()) :: {:ok, struct()} | {:error, :not_found}
  def lock(%schema{id: id} = record) do
    query = from(r in schema, where: r.id == ^id, lock: "FOR UPDATE", select: r.translations)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      translations -> {:ok, %{record | translations: translations}}
    end
  end

  @doc "Writes the translations in `changeset`."
  @spec update(Ecto.Changeset.t()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)
end
