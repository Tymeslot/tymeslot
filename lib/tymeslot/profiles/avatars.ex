defmodule Tymeslot.Profiles.Avatars do
  @moduledoc """
  Subcomponent for managing profile avatars.
  Handles file system operations and coordinates with ProfileQueries.
  """

  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.Utils.AvatarUtils
  alias TymeslotWeb.Helpers.UploadHandler

  alias Tymeslot.Utils.MediaValidator

  @type profile :: ProfileSchema.t()
  @type uploaded_entry :: map()
  @type result(t) :: {:ok, t} | {:error, any()}

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
    case profile.avatar do
      nil ->
        AvatarUtils.generate_fallback_data_uri(profile)

      "" ->
        AvatarUtils.generate_fallback_data_uri(profile)

      avatar ->
        if String.starts_with?(avatar, "/") do
          avatar
        else
          "/uploads/avatars/#{profile.id}/#{avatar}"
        end
    end
  end

  @doc """
  Gets appropriate alt text for the avatar image.
  """
  @spec avatar_alt_text(profile | nil) :: String.t()
  def avatar_alt_text(nil), do: "Profile"

  def avatar_alt_text(profile) do
    cond do
      profile.full_name && String.trim(profile.full_name) != "" ->
        profile.full_name

      profile.user && profile.user.email ->
        "Profile of #{profile.user.email}"

      true ->
        "Profile"
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
