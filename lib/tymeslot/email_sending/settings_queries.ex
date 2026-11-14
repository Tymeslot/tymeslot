defmodule Tymeslot.EmailSending.SettingsQueries do
  @moduledoc """
  Owner-scoped SMTP settings persistence. Revision checks happen again at the
  write boundary after network tests finish, so stale tests cannot win edits.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.DeliveryStatus
  alias Tymeslot.EmailSending.Sender
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

  @doc """
  Records a failure only against the selected enabled, tested SMTP revision.

  Repeated identical failures update at most once per five minutes. These
  operational fields do not change configuration revisions or test evidence,
  so reporting the first failed copy cannot invalidate its remaining copies.
  """
  @spec record_failure(Sender.t(), String.t(), DateTime.t()) :: :ok
  def record_failure(sender, code, now) do
    code = DeliveryStatus.sanitize(code)
    cutoff = DateTime.add(now, -5, :minute)

    sender
    |> current_sender_query()
    |> where(
      [s],
      is_nil(s.last_error) or s.last_error != ^code or is_nil(s.last_failed_at) or
        s.last_failed_at <= ^cutoff
    )
    |> Repo.update_all([set: [last_error: code, last_failed_at: now]], status_options())

    :ok
  end

  @doc "Clears a recorded account failure after actual relay acceptance, without revision changes."
  @spec clear_failure(Sender.t()) :: :ok
  def clear_failure(sender) do
    sender
    |> current_sender_query()
    |> where([s], not is_nil(s.last_error))
    |> Repo.update_all([set: [last_error: nil, last_failed_at: nil]], status_options())

    :ok
  end

  defp current_sender_query(sender) do
    from(s in UserSmtpSettingsSchema,
      where:
        s.user_id == ^sender.owner_id and s.id == ^sender.settings_id and
          s.revision == ^sender.revision and s.enabled and s.tested_revision == s.revision and
          not is_nil(s.tested_at) and s.from_name == ^sender.from_name and
          s.from_address == ^sender.from_address
    )
  end

  # Status follows SMTP acceptance but precedes the recipient's durable claim.
  # Never queue for a pool connection or consume its normal 15-second timeout:
  # EmailWorker budgets this extra bound for every recipient, including calendar
  # updates whose recipient count can exceed the booking and poll limits.
  defp status_options do
    timeout = DeliveryStatus.write_deadline_ms()

    [
      queue: false,
      timeout: timeout,
      deadline: System.monotonic_time(:millisecond) + timeout
    ]
  end

  defp stale_result({:error, %Changeset{errors: errors} = invalid}) do
    if Keyword.has_key?(errors, :revision), do: {:error, :stale}, else: {:error, invalid}
  end

  defp stale_result(result), do: result
end
