defmodule TymeslotWeb.Helpers.UploadHandler do
  @moduledoc """
  File-system helpers for stored uploads: atomic writes and safe deletes.

  Both go through `TymeslotWeb.Helpers.FileOperations` for path sanitisation,
  secure directory creation and error handling, so callers never assemble a
  destination path themselves.
  """

  alias TymeslotWeb.Helpers.FileOperations

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
