defmodule TymeslotWeb.Helpers.ThemeUploadHelper do
  @moduledoc """
  Helper module for handling theme background uploads.
  """

  alias Phoenix.LiveView
  alias Tymeslot.ThemeCustomizations

  @doc """
  Process background image upload with logging.
  """
  @spec process_background_image_upload(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def process_background_image_upload(socket, profile) do
    theme_id = get_theme_id(socket)

    uploaded_files =
      LiveView.consume_uploaded_entries(socket, :background_image, fn %{path: temp_path}, entry ->
        # We must copy the file INSIDE this callback, before it gets deleted
        file_info = %{path: temp_path, filename: entry.client_name}

        case ThemeCustomizations.store_background_image(profile.id, theme_id, file_info) do
          {:ok, stored_path} ->
            {:ok, stored_path}

          {:error, reason} ->
            {:postpone, {:error, reason}}
        end
      end)

    case uploaded_files do
      [stored_path] when is_binary(stored_path) ->
        attrs = %{
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => stored_path
        }

        case ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, attrs) do
          {:ok, _customization} ->
            {:ok, "Background image uploaded successfully"}

          {:error, _reason} ->
            {:error, "Failed to save background image"}
        end

      [] ->
        {:error, "No file was uploaded"}

      _error ->
        {:error, "Upload failed"}
    end
  end

  @doc """
  Process background video upload with logging.
  """
  @spec process_background_video_upload(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def process_background_video_upload(socket, profile) do
    theme_id = get_theme_id(socket)

    uploaded_files =
      LiveView.consume_uploaded_entries(socket, :background_video, fn %{path: temp_path}, entry ->
        # We must copy the file INSIDE this callback, before it gets deleted
        file_info = %{path: temp_path, filename: entry.client_name}

        case ThemeCustomizations.store_background_video(profile.id, theme_id, file_info) do
          {:ok, stored_path} ->
            {:ok, stored_path}

          {:error, reason} ->
            {:postpone, {:error, reason}}
        end
      end)

    case uploaded_files do
      [stored_path] when is_binary(stored_path) ->
        attrs = %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => stored_path
        }

        case ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, attrs) do
          {:ok, _customization} ->
            {:ok, "Background video uploaded successfully"}

          {:error, _reason} ->
            {:error, "Failed to save background video"}
        end

      [] ->
        {:error, "No file was uploaded"}

      _error ->
        {:error, "Upload failed"}
    end
  end

  @spec get_theme_id(Phoenix.LiveView.Socket.t()) :: String.t()
  defp get_theme_id(socket) do
    socket.assigns[:current_customization_theme_id] ||
      (socket.assigns[:component_props] && socket.assigns[:component_props][:theme_id]) ||
      "1"
  end
end
