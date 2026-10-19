defmodule Tymeslot.Profiles.Avatars do
  @moduledoc """
  Subcomponent for managing profile avatars.
  Handles file system operations and coordinates with ProfileQueries.
  """

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.MediaValidator
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.Avatars.Fallback
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Utils.UrlBuilder

  @type profile :: ProfileSchema.t()
  @type uploaded_entry :: %{
          optional(:client_name) => String.t(),
          required(:path) => String.t(),
          optional(atom()) => term()
        }
  @type result(t) :: {:ok, t} | {:error, any()}

  @typedoc "Why `validate_upload/1` refuses an upload."
  @type validation_error ::
          :invalid_file_type | {:file_too_large, pos_integer()} | :unreadable_file

  @accepted_extensions Uploads.allowed_extensions(:avatar)
  @max_file_size Uploads.max_file_size(:avatar)

  @doc "Returns the list of accepted avatar file extensions."
  @spec accepted_extensions() :: [String.t()]
  def accepted_extensions, do: @accepted_extensions

  @doc "Returns the maximum avatar file size in bytes."
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: @max_file_size

  @doc """
  Validates an avatar upload's file type and size.

  Expects a map with string keys: `"client_name"` and `"path"`. The size is
  read from the uploaded file itself, not from what the client reported.
  Returns `{:ok, file_params}`, or `{:error, reason}` with a reason the web
  layer words for the user (`TymeslotWeb.Helpers.ImageUploadErrors`).
  """
  @spec validate_upload(map()) :: {:ok, map()} | {:error, validation_error()}
  def validate_upload(file_params) do
    with :ok <- validate_file_type(file_params),
         :ok <- validate_file_size(file_params) do
      {:ok, file_params}
    end
  end

  # Validates the file extension against accepted avatar types.
  @spec validate_file_type(map()) :: :ok | {:error, :invalid_file_type}
  defp validate_file_type(%{"client_name" => filename}) when is_binary(filename) do
    extension = filename |> Path.extname() |> String.downcase()

    if extension in @accepted_extensions, do: :ok, else: {:error, :invalid_file_type}
  end

  defp validate_file_type(_file_params), do: {:error, :invalid_file_type}

  @spec validate_file_size(map()) ::
          :ok | {:error, {:file_too_large, pos_integer()} | :unreadable_file}
  defp validate_file_size(%{"path" => path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= @max_file_size -> :ok
      {:ok, %File.Stat{}} -> {:error, {:file_too_large, Uploads.max_file_size_mb(:avatar)}}
      {:error, _reason} -> {:error, :unreadable_file}
    end
  end

  defp validate_file_size(_file_params), do: {:error, :unreadable_file}

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
          Uploads.delete_safely(file_path, context)
        end

        {:ok, updated_profile}

      error ->
        error
    end
  end

  @doc """
  Removes every avatar file stored for a profile, including earlier uploads a
  replacement left behind. For erasing a profile that no longer exists: it
  touches no database row.
  """
  @spec delete_all_files(pos_integer()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_all_files(profile_id) when is_integer(profile_id) do
    [Uploads.root(), "avatars", Integer.to_string(profile_id)]
    |> Path.join()
    |> remove_directory()
  end

  @doc """
  The generated fallback avatar (initials on a colour derived from the
  profile) as a data URI, for a profile or profile-shaped map without an
  uploaded image. `nil` gives a generic avatar.
  """
  @spec fallback_data_uri(map() | nil, non_neg_integer()) :: String.t()
  defdelegate fallback_data_uri(profile, size \\ 300),
    to: Fallback,
    as: :generate_fallback_data_uri

  @doc """
  Gets the avatar URL for a profile.
  """
  @spec avatar_url(profile | nil, atom()) :: String.t()
  def avatar_url(profile, version \\ :original)
  def avatar_url(nil, _version), do: Fallback.generate_fallback_data_uri(nil)

  def avatar_url(%ProfileSchema{} = profile, _version) do
    case uploaded_avatar_path(profile) do
      nil -> Fallback.generate_fallback_data_uri(profile)
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
  Returns the absolute URL of a profile's *uploaded* avatar image, or `nil`
  when none has been uploaded.

  For images fetched from outside the app, such as by a mail client rendering
  an email. Like `uploaded_avatar_path/1`, it never returns a data URI, which
  Gmail refuses to render.
  """
  @spec uploaded_avatar_url(profile | nil) :: String.t() | nil
  def uploaded_avatar_url(profile) do
    case uploaded_avatar_path(profile) do
      nil -> nil
      path -> UrlBuilder.build_url(path)
    end
  end

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

  # The stored name and format come from the bytes, never from the client's
  # file name: a PNG sent as `photo.jpg` is stored and served as a PNG.
  defp store_avatar_file(uploaded_entry, profile) do
    profile_dir = Path.join([Uploads.root(), "avatars", to_string(profile.id)])

    # The avatar is public: it appears on the booking page, in embeds and in
    # email. Re-encoding drops the EXIF location and device details a phone
    # photo carries, and runs only once the content has passed the check.
    with {:ok, binary} <- File.read(uploaded_entry.path),
         :ok <- validate_image_binary(binary),
         {:ok, extension} <- ImageMetadata.extension(uploaded_entry.path),
         :ok <- File.mkdir_p(profile_dir),
         filename = Uploads.stored_name(extension),
         :ok <-
           ImageMetadata.strip(uploaded_entry.path, Path.join(profile_dir, filename), extension) do
      {:ok, filename}
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
    Uploads.delete_safely(old_file_path, Map.put(context, :file_type, "old_avatar"))
  end

  defp build_avatar_path(filename, profile) do
    Path.join(["avatars", to_string(profile.id), filename])
  end

  defp remove_directory(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, failed_path} -> {:error, reason, failed_path}
    end
  end
end
