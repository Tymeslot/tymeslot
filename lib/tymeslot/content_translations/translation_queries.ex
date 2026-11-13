defmodule Tymeslot.ContentTranslations.TranslationQueries do
  @moduledoc """
  Writes a record's `translations` column, for every translated table
  (`profiles`, `booking_pages`, `meeting_types`, `venues`). The changeset is
  `Tymeslot.ContentTranslations.changeset/2`, which casts that column alone.
  """

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.Repo

  @doc """
  `record` as its row stands now, locked `FOR UPDATE` until the surrounding
  transaction ends, so a save built on it cannot overwrite another committed
  in the meantime, nor stamp its translations against originals since
  changed. The associations and virtual fields `record` had loaded are
  carried over as they were.
  """
  @spec lock(struct()) :: {:ok, struct()} | {:error, :not_found}
  def lock(%schema{id: id} = record) do
    query = from(r in schema, where: r.id == ^id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      locked -> {:ok, struct(locked, caller_fields(record))}
    end
  end

  # The row carries columns alone: what the caller had loaded beyond them
  # (associations, virtual fields) is the caller's.
  defp caller_fields(%schema{} = record) do
    keys = schema.__schema__(:associations) ++ schema.__schema__(:virtual_fields)

    record
    |> Map.take(keys)
    |> Map.reject(fn {_key, value} -> match?(%Ecto.Association.NotLoaded{}, value) end)
  end

  @doc "Writes the translations in `changeset`."
  @spec update(Ecto.Changeset.t()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{} = changeset), do: Repo.update(changeset)
end
