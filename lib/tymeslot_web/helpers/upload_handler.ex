defmodule TymeslotWeb.Helpers.UploadHandler do
  @moduledoc """
  Helpers for stored uploads: settling LiveView upload entries before they are
  consumed, plus atomic writes and safe deletes.

  The file-system pair goes through `TymeslotWeb.Helpers.FileOperations` for
  path sanitisation, secure directory creation and error handling, so callers
  never assemble a destination path themselves.
  """

  alias Phoenix.LiveView
  alias TymeslotWeb.Helpers.FileOperations

  @doc """
  Discards the entries of `upload_key` that can never finish, and reports
  whether what remains is safe to consume.

  `consume_uploaded_entries/3` raises `ArgumentError` if *any* entry on the
  upload is still in progress, and an auto-upload's `progress` callback runs
  once per entry: the entry it hands the caller being `done?` says nothing
  about that entry's siblings. A caller that reads only its own entry is
  therefore one concurrent selection away from crashing the LiveView.

  An entry the client rejected — over `max_file_size`, past `max_entries`,
  wrong extension — is never uploaded at all, so it stays not-done for the
  life of the LiveView. Waiting for it would block every later upload on that
  key, so those entries are cancelled here rather than waited on.

  Returns the (possibly updated) socket and `:settled` when consuming is safe,
  or `:in_progress` when an entry is still genuinely uploading.
  """
  @spec settle_upload(Phoenix.LiveView.Socket.t(), atom()) ::
          {Phoenix.LiveView.Socket.t(), :settled | :in_progress}
  def settle_upload(socket, upload_key) when is_atom(upload_key) do
    socket =
      socket
      |> upload_entries(upload_key)
      |> Enum.reject(& &1.valid?)
      |> Enum.reduce(socket, &LiveView.cancel_upload(&2, upload_key, &1.ref))

    case Enum.reject(upload_entries(socket, upload_key), & &1.done?) do
      [] -> {socket, :settled}
      _still_uploading -> {socket, :in_progress}
    end
  end

  @doc """
  The current entries for `upload_key`, or `[]` when the upload is not
  configured on this socket.
  """
  @spec upload_entries(Phoenix.LiveView.Socket.t(), atom()) :: [
          Phoenix.LiveView.UploadEntry.t()
        ]
  def upload_entries(socket, upload_key) when is_atom(upload_key) do
    case socket.assigns[:uploads] do
      %{^upload_key => %{entries: entries}} -> entries
      _not_configured -> []
    end
  end

  @doc """
  Handles file storage with atomic operations and proper cleanup.
  """
  @spec store_file_atomically(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_file_atomically(source_path, dest_dir, filename, context \\ %{}) do
    with {:ok, secure_dest_dir} <-
           FileOperations.validate_and_sanitize_path(get_upload_base_dir(), dest_dir),
         :ok <- FileOperations.ensure_secure_directory(secure_dest_dir),
         sanitized_filename <- FileOperations.sanitize_filename(filename),
         dest_path <- Path.join(secure_dest_dir, sanitized_filename),
         {:ok, _final_path} <- FileOperations.atomic_file_move(source_path, dest_path, context) do
      {:ok, sanitized_filename}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Safely deletes a file using robust error handling.
  """
  @spec delete_file_safely(String.t(), map()) :: :ok | {:error, term()}
  def delete_file_safely(file_path, context \\ %{}) do
    FileOperations.safe_delete_file(file_path, context)
  end

  # Private helpers

  defp get_upload_base_dir do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end
end
