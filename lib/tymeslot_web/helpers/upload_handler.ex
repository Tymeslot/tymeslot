defmodule TymeslotWeb.Helpers.UploadHandler do
  @moduledoc """
  Helpers for stored uploads: settling LiveView upload entries before they are
  consumed, plus atomic writes and safe deletes.

  The file-system pair goes through `TymeslotWeb.Helpers.FileOperations` for
  path sanitisation, secure directory creation and error handling, so callers
  never assemble a destination path themselves.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.LiveView.UploadConfig
  alias TymeslotWeb.Helpers.FileOperations

  # LiveView records the `max_entries` breach against the upload config rather
  # than against the offending entry, so it arrives through `upload_errors/1`.
  @too_many_files :too_many_files

  @doc """
  Discards the entries of `upload_key` that can never finish, and reports
  whether what remains is safe to consume.

  `consume_uploaded_entries/3` raises `ArgumentError` if *any* entry on the
  upload is still in progress, and an auto-upload's `progress` callback runs
  once per entry: the entry it hands the caller being `done?` says nothing
  about that entry's siblings. A caller that reads only its own entry is
  therefore one concurrent selection away from crashing the LiveView.

  Two kinds of entry never finish, and both are cancelled here rather than
  waited on, because either would block every later upload on that key for the
  life of the LiveView:

    * one that failed validation — over `max_file_size`, wrong extension — and
      so is never uploaded at all;
    * one selected past `max_entries`. Preflight issues upload tokens only to
      entries inside the limit, so an excess entry can never make progress,
      yet it is `valid?: true`: LiveView keys `:too_many_files` on the upload
      config, not on the entry.

  An entry merely waiting for its preflight round trip looks identical to an
  excess one, so "not preflighted" alone is not the discriminator; it only
  means stalled once the upload is reporting that it is full.

  Returns the (possibly updated) socket and `:settled` when consuming is safe,
  or `:in_progress` when an entry is still genuinely uploading.
  """
  @spec settle_upload(Phoenix.LiveView.Socket.t(), atom()) ::
          {Phoenix.LiveView.Socket.t(), :settled | :in_progress}
  def settle_upload(socket, upload_key) when is_atom(upload_key) do
    full? = upload_full?(socket, upload_key)

    socket =
      socket
      |> upload_entries(upload_key)
      |> Enum.filter(&stalled?(&1, full?))
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

  # Rejected outright: the client never uploads it.
  defp stalled?(%{valid?: false}, _full?), do: true
  # Still awaiting a token it can only be granted from inside `max_entries`.
  defp stalled?(%{done?: false, preflighted?: false}, full?), do: full?
  defp stalled?(_entry, _full?), do: false

  defp upload_full?(socket, upload_key) do
    case socket.assigns[:uploads] do
      %{^upload_key => %UploadConfig{} = conf} -> @too_many_files in Component.upload_errors(conf)
      _not_configured -> false
    end
  end

  defp get_upload_base_dir do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end
end
