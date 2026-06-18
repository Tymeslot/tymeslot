defmodule Tymeslot.Profiles.Avatars do
  @moduledoc """
  Subcomponent for managing profile avatars.
  Handles file system operations and coordinates with ProfileQueries.
  """

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Utils.AvatarUtils
  alias Tymeslot.Utils.MediaValidator
  alias TymeslotWeb.Helpers.UploadHandler

  @type profile :: ProfileSchema.t()
  @type uploaded_entry :: %{
          required(:client_name) => String.t(),
          required(:path) => String.t(),
          optional(atom()) => term()
        }
  @type result(t) :: {:ok, t} | {:error, any()}

  @accepted_extensions ~w(.jpg .jpeg .png .gif .webp)
  @max_file_size 10_000_000

  @doc "Returns the list of accepted avatar file extensions."
  @spec accepted_extensions() :: [String.t()]
  def accepted_extensions, do: @accepted_extensions

  @doc "Returns the maximum avatar file size in bytes."
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: @max_file_size

  @doc """
  Validates an avatar upload's file type, size, and name.

  Expects a map with string keys: `"client_name"`, `"size"`, and `"path"`.
  Returns `{:ok, file_params}` on success or `{:error, reason}` on failure.
  """
  @spec validate_upload(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_upload(file_params) do
    with :ok <- validate_file_type(file_params),
         :ok <- validate_file_size(file_params),
         :ok <- validate_file_name(file_params) do
      {:ok, file_params}
    end
  end

  @doc "Validates the file extension against accepted avatar types."
  @spec validate_file_type(map()) :: :ok | {:error, String.t()}
  def validate_file_type(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        extension = filename |> Path.extname() |> String.downcase()

        if extension in @accepted_extensions do
          :ok
        else
          {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}
        end
    end
  end

  @doc "Validates the file size against the maximum allowed."
  @spec validate_file_size(map()) :: :ok | {:error, String.t()}
  def validate_file_size(file_params) do
    case Map.get(file_params, "size") do
      nil ->
        :ok

      size when is_integer(size) ->
        if size <= @max_file_size,
          do: :ok,
          else: {:error, "File too large. Maximum size is 10MB"}

      _other ->
        {:error, "Invalid file size"}
    end
  end

  @doc "Validates the file name for path traversal and illegal characters."
  @spec validate_file_name(map()) :: :ok | {:error, String.t()}
  def validate_file_name(file_params) do
    case Map.get(file_params, "client_name") do
      nil ->
        {:error, "No file name provided"}

      filename ->
        cond do
          String.contains?(filename, ["../", "..\\", "\0"]) ->
            {:error, "Invalid file name"}

          String.match?(filename, ~r/[<>:"\\|?*]/) ->
            {:error, "Invalid file name"}

          String.length(filename) > 255 ->
            {:error, "File name too long"}

          true ->
            :ok
        end
    end
  end

  @doc """
  Updates a user's avatar file and database record.
  """
  @spec update_avatar(profile, uploaded_entry) :: result(profile)
  def update_avatar(%ProfileSchema{} = profile, uploaded_entry) do
    old_avatar = profile.avatar
    context = %{user_id: profile.id, operation: "avatar_update"}

    with {:ok, filename} <- store_avatar_file(uploaded_entry, profile),
         {:ok, updated_profile} <- ProfileQueries.update_avatar(profile, filename) do
      maybe_delete_old_avatar(old_avatar, profile, context)
      {:ok, updated_profile}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a user's avatar file and updates database record.
  """
  @spec delete_avatar(profile) :: result(profile)
  def delete_avatar(%ProfileSchema{} = profile) do
    context = %{user_id: profile.id, operation: "avatar_delete"}

    case ProfileQueries.remove_avatar(profile) do
      {:ok, updated_profile} ->
        if profile.avatar do
          file_path = build_avatar_path(profile.avatar, profile)
          UploadHandler.delete_file_safely(file_path, context)
        end

        {:ok, updated_profile}

      error ->
        error
    end
  end

  @doc """
  Gets the avatar URL for a profile.
  """
  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original)
  def avatar_url(nil, _version), do: AvatarUtils.generate_fallback_data_uri(nil)

  def avatar_url(%ProfileSchema{} = profile, _version) do
    case uploaded_avatar_path(profile) do
      nil -> AvatarUtils.generate_fallback_data_uri(profile)
      path -> path
    end
  end

  @doc """
  Returns the public path to a profile's *uploaded* avatar image, or `nil`
  when no real image has been uploaded.

  Unlike `avatar_url/2`, this never falls back to a generated initials data URI.
  It is intended for contexts that require a real, fetchable image URL — e.g.
  Open Graph / social-share meta tags — where a data URI is not usable.
  """
  @spec uploaded_avatar_path(profile | nil) :: String.t() | nil
  def uploaded_avatar_path(%ProfileSchema{avatar: avatar} = profile)
      when is_binary(avatar) and avatar != "" do
    if String.starts_with?(avatar, "/"),
      do: avatar,
      else: "/uploads/avatars/#{profile.id}/#{avatar}"
  end

  def uploaded_avatar_path(_profile), do: nil

  @doc """
  Gets appropriate alt text for the avatar image.
  """
  @spec avatar_alt_text(profile | nil) :: String.t()
  def avatar_alt_text(nil), do: "Profile"

  def avatar_alt_text(profile) do
    case Profiles.display_name(profile) do
      nil -> "Profile"
      name -> name
    end
  end

  # Private helpers

  defp store_avatar_file(uploaded_entry, profile) do
    timestamp = System.system_time(:second)
    unique_suffix = System.unique_integer([:positive])
    extension = String.downcase(Path.extname(uploaded_entry.client_name))
    filename = "#{profile.id}_avatar_#{timestamp}_#{unique_suffix}#{extension}"

    upload_dir = get_upload_directory()
    profile_dir = Path.join([upload_dir, "avatars", to_string(profile.id)])

    with :ok <- File.mkdir_p(profile_dir),
         {:ok, binary} <- File.read(uploaded_entry.path),
         :ok <- validate_image_binary(binary),
         :ok <- File.cp(uploaded_entry.path, Path.join(profile_dir, filename)) do
      {:ok, filename}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_image_binary(binary) do
    if MediaValidator.valid_image?(binary) do
      :ok
    else
      {:error, :invalid_image_format}
    end
  end

  defp maybe_delete_old_avatar(nil, _profile, _context), do: :ok

  defp maybe_delete_old_avatar(old_avatar, profile, context) do
    old_file_path = build_avatar_path(old_avatar, profile)
    UploadHandler.delete_file_safely(old_file_path, Map.put(context, :file_type, "old_avatar"))
  end

  defp build_avatar_path(filename, profile) do
    upload_dir = get_upload_directory()
    Path.join([upload_dir, "avatars", to_string(profile.id), filename])
  end

  defp get_upload_directory do
    Application.get_env(:tymeslot, :upload_directory, "uploads")
  end
end
