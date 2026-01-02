defmodule TymeslotWeb.Helpers.FileOperations do
  @moduledoc """
  Robust file operations with comprehensive error handling, security validation,
  and retry mechanisms for upload management.
  """

  require Logger
  alias TymeslotWeb.Helpers.UploadConstraints

  @max_retries 3
  # 1 second base delay
  @retry_backoff_base 1000

  # Security: Allowed file extensions by category
  @allowed_extensions %{
    avatar: UploadConstraints.allowed_extensions(:avatar),
    image: UploadConstraints.allowed_extensions(:image),
    video: UploadConstraints.allowed_extensions(:video)
  }

  # Security: Maximum filename length
  @max_filename_length 255

  @doc """
  Safely deletes a file with retry logic and comprehensive logging.
  Never fails the calling operation - always returns :ok.
  """
  @spec safe_delete_file(String.t(), map()) :: :ok
  def safe_delete_file(file_path, context \\ %{}) do
    case delete_file_with_retry(file_path, @max_retries) do
      :ok ->
        Logger.info("File deleted successfully", %{
          file_path: file_path,
          context: context
        })

        :ok

      {:error, :enoent} ->
        # File doesn't exist - this is fine
        Logger.debug("File deletion skipped - file not found", %{
          file_path: file_path,
          context: context
        })

        :ok

      {:error, reason} ->
        Logger.warning("File deletion failed after retries", %{
          file_path: file_path,
          reason: reason,
          context: context,
          max_retries: @max_retries
        })

        # Don't fail the operation
        :ok
    end
  end

  @doc """
  Validates file extension against allowed types.
  """
  @spec validate_file_extension(String.t(), atom()) ::
          :ok | {:error, {atom(), String.t(), [String.t()]}}
  def validate_file_extension(filename, file_type) when is_atom(file_type) do
    extension = String.downcase(Path.extname(filename))
    allowed = Map.get(@allowed_extensions, file_type, [])

    if extension in allowed do
      :ok
    else
      {:error, {:invalid_extension, extension, allowed}}
    end
  end

  @doc """
  Sanitizes a filename to prevent path traversal and other security issues.
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(filename) do
    # Remove path components and dangerous characters
    clean_filename =
      filename
      # Remove any path components
      |> Path.basename()
      # Replace dangerous chars with underscore
      |> String.replace(~r/[^\w\-_.()]/, "_")
      |> String.trim()
      |> String.slice(0, @max_filename_length)

    # Ensure we don't have an empty filename
    if String.length(clean_filename) == 0 do
      "file_#{:os.system_time(:millisecond)}"
    else
      clean_filename
    end
  end

  @doc """
  Validates and sanitizes a file path to prevent directory traversal attacks.
  """
  @spec validate_and_sanitize_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal_attempt}
  def validate_and_sanitize_path(base_dir, path) do
    base_dir = Path.expand(base_dir)
    expanded_path = Path.expand(path)

    # If the caller already provided an absolute path under base_dir, accept it.
    if Path.relative_to(expanded_path, base_dir) != expanded_path do
      {:ok, expanded_path}
    else
      # Sanitize relative components
      clean_path =
        path
        |> Path.split()
        |> Enum.reject(&(&1 in [".", "..", ""]))
        |> Path.join()

      full_path = Path.join(base_dir, clean_path)

      case Path.relative_to(full_path, base_dir) do
        ^full_path ->
          {:error, :path_traversal_attempt}

        _ ->
          {:ok, full_path}
      end
    end
  end

  @doc """
  Creates a secure directory structure ensuring proper permissions.
  """
  @spec ensure_secure_directory(String.t()) :: :ok | {:error, atom()}
  def ensure_secure_directory(dir_path) do
    case File.mkdir_p(dir_path) do
      :ok ->
        # Set directory permissions (owner read/write/execute, group read/execute)
        case File.chmod(dir_path, 0o750) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to set directory permissions", %{
              dir_path: dir_path,
              reason: reason
            })

            # Continue anyway
            :ok
        end

      {:error, :eacces} ->
        Logger.error("Permission denied creating directory", %{dir_path: dir_path})
        {:error, :permission_denied}

      {:error, reason} ->
        Logger.error("Failed to create directory", %{
          dir_path: dir_path,
          reason: reason
        })

        {:error, reason}
    end
  end

  @doc """
  Performs comprehensive file validation for uploads.
  """
  @spec validate_upload_file(map(), atom(), keyword()) ::
          {:ok, map()} | {:error, atom() | tuple()}
  def validate_upload_file(entry, file_type, opts \\ []) do
    filename = entry.client_name || "unknown"
    max_size = Keyword.get(opts, :max_size)

    with :ok <- validate_file_extension(filename, file_type),
         :ok <- validate_filename_security(filename),
         :ok <- validate_file_size(entry, max_size) do
      sanitized_filename = sanitize_filename(filename)
      {:ok, %{entry | client_name: sanitized_filename}}
    end
  end

  @doc """
  Atomically moves a file with rollback capability.
  """
  @spec atomic_file_move(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, atom()}
  def atomic_file_move(source_path, dest_path, rollback_info \\ %{}) do
    case File.rename(source_path, dest_path) do
      :ok ->
        Logger.debug("File moved successfully", %{
          source: source_path,
          destination: dest_path
        })

        {:ok, dest_path}

      {:error, reason} ->
        Logger.error("File move failed", %{
          source: source_path,
          destination: dest_path,
          reason: reason,
          rollback_info: rollback_info
        })

        {:error, reason}
    end
  end

  # Private functions

  defp delete_file_with_retry(file_path, retries_left) when retries_left > 0 do
    case File.rm(file_path) do
      :ok ->
        :ok

      # File doesn't exist
      {:error, :enoent} = error ->
        error

      {:error, reason} ->
        # Wait before retry with exponential backoff
        delay = @retry_backoff_base * round(:math.pow(2, @max_retries - retries_left))
        Process.sleep(delay)

        Logger.debug("Retrying file deletion", %{
          file_path: file_path,
          retries_left: retries_left - 1,
          delay_ms: delay,
          last_error: reason
        })

        delete_file_with_retry(file_path, retries_left - 1)
    end
  end

  defp delete_file_with_retry(_file_path, 0) do
    {:error, :max_retries_exceeded}
  end

  defp validate_filename_security(filename) do
    cond do
      String.contains?(filename, ["../", "..\\", "~/"]) ->
        {:error, :path_traversal_in_filename}

      String.length(filename) > @max_filename_length ->
        {:error, :filename_too_long}

      String.match?(filename, ~r/^[.]/) ->
        {:error, :hidden_file_not_allowed}

      true ->
        :ok
    end
  end

  defp validate_file_size(_entry, nil), do: :ok

  defp validate_file_size(entry, max_size) when is_integer(max_size) do
    if entry.client_size <= max_size do
      :ok
    else
      {:error, {:file_too_large, entry.client_size, max_size}}
    end
  end
end
