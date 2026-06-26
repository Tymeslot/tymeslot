defmodule TymeslotWeb.Helpers.AttachmentUpload do
  @moduledoc """
  File storage for host-uploaded meeting-type attachments.

  Owns the on-disk side of the feature (the domain only persists metadata):
  validates the extension and size against `UploadConstraints`, sanitises the
  filename, and stores the file under
  `uploads/attachments/<user_id>/<meeting_type_id>/`. The MIME type is derived
  from the (sanitised) extension rather than trusting the browser-supplied
  value, and the served file is forced to download with `nosniff` by
  `UploadStaticSecurity`.
  """

  alias TymeslotWeb.Helpers.FileOperations
  alias TymeslotWeb.Helpers.UploadConstraints
  alias TymeslotWeb.Helpers.UploadHandler

  @type entry :: %{
          required(:path) => String.t(),
          required(:client_name) => String.t(),
          optional(:client_size) => non_neg_integer()
        }

  @doc """
  Stores one uploaded entry and returns its metadata map (string keys), ready
  to hand to `Tymeslot.MeetingTypes.add_attachment/2`.
  """
  @spec store(integer(), integer(), entry()) :: {:ok, map()} | {:error, term()}
  def store(user_id, meeting_type_id, %{path: path, client_name: client_name}) do
    relative_dir = Path.join(["attachments", to_string(user_id), to_string(meeting_type_id)])
    # Capture the size before storing — `store_file_atomically` moves the
    # source file away, after which `path` no longer exists.
    byte_size = file_size(path)

    with :ok <- validate_extension(client_name),
         :ok <- validate_size(byte_size),
         {:ok, stored_name} <-
           UploadHandler.store_file_atomically(
             path,
             relative_dir,
             unique_name(client_name),
             %{operation: :store_attachment, user_id: user_id}
           ) do
      {:ok,
       %{
         "filename" => FileOperations.sanitize_filename(client_name),
         "stored_path" => Path.join(relative_dir, stored_name),
         "content_type" => mime_for(client_name),
         "byte_size" => byte_size
       }}
    end
  end

  @doc "Deletes a stored attachment file by its uploads-relative `stored_path`."
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok

  def delete(stored_path) when is_binary(stored_path) do
    UploadHandler.delete_file_safely(Path.join(base_dir(), stored_path), %{
      operation: :delete_attachment
    })

    :ok
  end

  defp validate_extension(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    if ext in UploadConstraints.allowed_extensions(:attachment),
      do: :ok,
      else: {:error, :unsupported_file_type}
  end

  defp validate_size(byte_size) do
    if byte_size <= UploadConstraints.max_file_size(:attachment),
      do: :ok,
      else: {:error, :file_too_large}
  end

  defp unique_name(client_name) do
    ext = client_name |> Path.extname() |> String.downcase()
    base = client_name |> Path.rootname() |> Path.basename()
    "#{System.system_time(:second)}_#{System.unique_integer([:positive])}_#{base}#{ext}"
  end

  defp mime_for(filename) do
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    MIME.type(ext)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _error -> 0
    end
  end

  defp base_dir, do: Application.get_env(:tymeslot, :upload_directory, "uploads")
end
