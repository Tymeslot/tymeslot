defmodule Tymeslot.ContentTranslations.TranslationQueries do
  @moduledoc """
  Writes a record's `translations` column, for every translated table
  (`profiles`, `booking_pages`, `meeting_types`, `venues`). The changeset is
  `Tymeslot.ContentTranslations.changeset/2`, which casts that column alone.
  """

  alias Tymeslot.Repo

  @doc "Writes the translations in `changeset`."
  @spec update(Ecto.Changeset.t()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)
end
