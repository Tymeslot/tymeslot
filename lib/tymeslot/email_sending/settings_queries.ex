defmodule Tymeslot.EmailSending.SettingsQueries do
  @moduledoc """
  Owner-scoped SMTP settings persistence. Revision checks happen again at the
  write boundary after network tests finish, so stale tests cannot win edits.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Repo

  @doc "Returns the owner's settings, without decrypting credentials."
  @spec get_for_user(pos_integer()) :: UserSmtpSettingsSchema.t() | nil
  def get_for_user(user_id), do: Repo.get_by(UserSmtpSettingsSchema, user_id: user_id)

  @doc "Inserts a new tested configuration, translating a concurrent create to stale."
  @spec insert(Changeset.t()) :: {:ok, UserSmtpSettingsSchema.t()} | {:error, term()}
  def insert(changeset) do
    case Repo.insert(changeset) do
      {:error, %Changeset{errors: errors} = invalid} ->
        if Keyword.has_key?(errors, :user_id), do: {:error, :stale}, else: {:error, invalid}

      result ->
        result
    end
  end

  @doc "Updates a loaded owner-scoped row only while its revision still matches."
  @spec update(Changeset.t()) :: {:ok, UserSmtpSettingsSchema.t()} | {:error, term()}
  def update(changeset) do
    changeset
    |> Changeset.optimistic_lock(:revision)
    |> Repo.update(stale_error_field: :revision)
    |> stale_result()
  end

  @doc "Deletes only the owner's matching revision, including its stored credentials."
  @spec delete(pos_integer(), pos_integer(), pos_integer()) :: :ok | {:error, :stale}
  def delete(user_id, id, revision) do
    query =
      from(s in UserSmtpSettingsSchema,
        where: s.user_id == ^user_id and s.id == ^id and s.revision == ^revision
      )

    case Repo.delete_all(query) do
      {1, _deleted_rows} -> :ok
      {0, _deleted_rows} -> {:error, :stale}
    end
  end

  defp stale_result({:error, %Changeset{errors: errors} = invalid}) do
    if Keyword.has_key?(errors, :revision), do: {:error, :stale}, else: {:error, invalid}
  end

  defp stale_result(result), do: result
end
