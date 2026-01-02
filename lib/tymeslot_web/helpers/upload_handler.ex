defmodule TymeslotWeb.Helpers.UploadHandler do
  @moduledoc """
  Centralized handler for file uploads with auto-upload support.
  Provides common functionality for handling uploads, resetting configurations,
  and managing upload lifecycle across different contexts (avatar, theme backgrounds, etc.).
  """

  alias Phoenix.LiveView
  alias TymeslotWeb.Helpers.{ClientIP, FileOperations, UploadConstraints}
  require Logger

  @doc """
  Resets upload configuration for a given upload key.
  Used after successful upload or deletion to ensure clean state.
  """
  @spec reset_upload(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def reset_upload(socket, upload_key) when is_atom(upload_key) do
    if socket.assigns[:uploads] && socket.assigns.uploads[upload_key] do
      socket
      |> LiveView.disallow_upload(upload_key)
      |> configure_upload(upload_key, get_upload_opts(upload_key))
    else
      # Upload not configured, just configure it fresh
      configure_upload(socket, upload_key, get_upload_opts(upload_key))
    end
  end

  @doc """
  Configures an upload with the given options.
  """
  @spec configure_upload(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def configure_upload(socket, upload_key, opts) do
    LiveView.allow_upload(socket, upload_key, opts)
  end

  @doc """
  Gets security metadata from socket for validation.
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket),
      user_id: get_user_id(socket)
    }
  end

  @doc """
  Consumes uploaded entries and processes them with the given handler function.
  Returns a list of results from the handler.
  """
  @spec consume_uploads(Phoenix.LiveView.Socket.t(), atom(), function()) :: list()
  def consume_uploads(socket, upload_key, handler_fn) do
    LiveView.consume_uploaded_entries(socket, upload_key, handler_fn)
  end

  @doc """
  Pushes an event to clear file inputs in JavaScript after successful upload.
  """
  @spec push_upload_complete_event(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def push_upload_complete_event(socket, event_name \\ "upload-complete") do
    LiveView.push_event(socket, event_name, %{})
  end

  @doc """
  Sends update to a component with upload results.
  """
  @spec send_upload_result_to_component(module(), String.t(), atom(), list()) :: :ok
  def send_upload_result_to_component(component_module, component_id, result_key, results) do
    updates = Map.new([{:id, component_id}, {result_key, results}])
    LiveView.send_update(component_module, updates)
  end

  @doc """
  Standard upload configuration for different upload types.
  """
  @spec get_upload_opts(atom()) :: keyword()
  def get_upload_opts(:avatar) do
    exts = UploadConstraints.allowed_extensions(:avatar)

    [
      accept: exts,
      max_entries: 1,
      max_file_size: UploadConstraints.max_file_size(:avatar)
    ]
  end

  @spec get_upload_opts(atom()) :: keyword()
  def get_upload_opts(:background_image) do
    exts = UploadConstraints.allowed_extensions(:image)

    [
      accept: exts,
      max_entries: 1,
      max_file_size: UploadConstraints.max_file_size(:image)
    ]
  end

  @spec get_upload_opts(atom()) :: keyword()
  def get_upload_opts(:background_video) do
    exts = UploadConstraints.allowed_extensions(:video)

    [
      accept: exts,
      max_entries: 1,
      max_file_size: UploadConstraints.max_file_size(:video)
    ]
  end

  @spec get_upload_opts(atom()) :: keyword()
  def get_upload_opts(_) do
    [
      accept: :any,
      max_entries: 1,
      max_file_size: UploadConstraints.max_file_size(:avatar)
    ]
  end

  @doc """
  Unified upload processing with comprehensive validation and error handling.
  """
  @spec process_upload(Phoenix.LiveView.Socket.t(), atom(), atom(), function(), map()) :: list()
  def process_upload(socket, upload_key, upload_type, processor_fn, metadata \\ %{}) do
    file_type = map_upload_type_to_file_type(upload_type)
    max_size = get_max_file_size(upload_type)

    uploaded_files =
      consume_uploads(socket, upload_key, fn %{path: path}, entry ->
        # Comprehensive validation pipeline
        with {:ok, validated_entry} <-
               FileOperations.validate_upload_file(entry, file_type, max_size: max_size),
             {:ok, processed_entry} <-
               processor_fn.(%{path: path, entry: validated_entry}, metadata) do
          {:ok, processed_entry}
        else
          {:error, reason} ->
            Logger.warning("Upload validation failed", %{
              upload_key: upload_key,
              upload_type: upload_type,
              reason: reason,
              filename: entry.client_name,
              metadata: metadata
            })

            {:postpone, reason}
        end
      end)

    uploaded_files
  end

  @doc """
  Legacy avatar upload handler - delegates to unified processor.
  """
  @spec handle_avatar_upload(Phoenix.LiveView.Socket.t(), term(), map(), module()) :: list()
  def handle_avatar_upload(socket, _profile, metadata, processor_module) do
    processor_fn = fn %{path: path, entry: entry}, meta ->
      uploaded_entry = %{
        "path" => path,
        "client_name" => entry.client_name
      }

      case processor_module.validate_avatar_upload(uploaded_entry, metadata: meta) do
        {:ok, validated_entry} ->
          {:ok,
           %{
             path: validated_entry["path"],
             client_name: validated_entry["client_name"]
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    process_upload(socket, :avatar, :avatar, processor_fn, metadata)
  end

  @doc """
  Checks if uploads need to be configured for a specific page/action.
  """
  @spec maybe_configure_uploads(Phoenix.LiveView.Socket.t(), atom(), map()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_configure_uploads(socket, action, uploads_config) do
    Enum.reduce(uploads_config[action] || [], socket, fn upload_key, acc ->
      if acc.assigns[:uploads] && acc.assigns.uploads[upload_key] do
        # Already configured
        acc
      else
        configure_upload(acc, upload_key, get_upload_opts(upload_key))
      end
    end)
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

  @doc """
  Creates a unified upload result structure.
  """
  @spec create_upload_result(atom(), map(), list()) :: map()
  def create_upload_result(status, data \\ %{}, errors \\ []) do
    %{
      status: status,
      data: data,
      errors: errors,
      timestamp: DateTime.utc_now()
    }
  end

  # Private helpers

  defp get_user_id(socket) do
    cond do
      socket.assigns[:current_user] -> socket.assigns.current_user.id
      socket.assigns[:user] -> socket.assigns.user.id
      true -> nil
    end
  end

  defp map_upload_type_to_file_type(:avatar) do
    :avatar
  end

  defp map_upload_type_to_file_type(:background_image) do
    :image
  end

  defp map_upload_type_to_file_type(:background_video) do
    :video
  end

  # Default fallback
  defp map_upload_type_to_file_type(_) do
    :avatar
  end

  defp get_max_file_size(:avatar) do
    UploadConstraints.max_file_size(:avatar)
  end

  defp get_max_file_size(:background_image) do
    UploadConstraints.max_file_size(:image)
  end

  defp get_max_file_size(:background_video) do
    UploadConstraints.max_file_size(:video)
  end

  defp get_max_file_size(_) do
    UploadConstraints.max_file_size(:avatar)
  end

  defp get_upload_base_dir do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end
end
