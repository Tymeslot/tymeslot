defmodule Tymeslot.Media.Uploads do
  @moduledoc """
  Where uploaded files live and how they get there: the upload root, the
  per-kind limits, atomic stores, safe deletes and the containment check that
  keeps every one of them inside the root.

  Stored paths are relative to `root/0` (`avatars/12/<name>`,
  `themes/12/1/videos/<name>`, `branding/<name>`), so moving the volume only
  changes configuration. Files are always named by the server (`stored_name/1`)
  from the type detected in their bytes, never from the client's file name.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.AdminAlerts

  @type kind :: :avatar | :image | :video | :captions

  @max_sizes %{
    avatar: 10_000_000,
    image: 20_000_000,
    video: 100_000_000,
    captions: 200_000
  }

  # Background videos are MP4 or WebM, the formats every browser plays.
  # QuickTime bytes that arrive under an accepted name are stored as `.mp4`
  # and stripped like any other MP4 (see `MediaValidator.valid_video?/1`).
  @extensions %{
    avatar: [".jpg", ".jpeg", ".png", ".gif", ".webp"],
    image: [".jpg", ".jpeg", ".png", ".webp"],
    video: [".mp4", ".webm"],
    captions: [".vtt"]
  }

  @directory_mode 0o750

  @doc """
  The directory every upload is stored under. Read at runtime: tests and
  releases point it somewhere else after compilation.
  """
  @spec root() :: Path.t()
  def root, do: Application.get_env(:tymeslot, :upload_directory, "uploads")

  @doc "The file extensions (lower case, with the dot) accepted for `kind`."
  @spec allowed_extensions(kind()) :: [String.t()]
  def allowed_extensions(kind), do: Map.fetch!(@extensions, kind)

  @doc "The largest file, in bytes, accepted for `kind`."
  @spec max_file_size(kind()) :: pos_integer()
  def max_file_size(kind), do: Map.fetch!(@max_sizes, kind)

  @doc """
  The largest file accepted for `kind` in whole megabytes, as the dashboard
  states it to the organiser. Captions are measured in kilobytes and have no
  megabyte figure.
  """
  @spec max_file_size_mb(:avatar | :image | :video) :: pos_integer()
  def max_file_size_mb(kind) when kind in [:avatar, :image, :video],
    do: div(max_file_size(kind), 1_000_000)

  @doc """
  A fresh server-chosen file name carrying `extension` (with its dot), as
  detected from the file's contents.
  """
  @spec stored_name(String.t()) :: String.t()
  def stored_name("." <> _rest = extension), do: UUID.generate() <> extension

  @doc """
  Resolves `path` (relative to the root, or absolute) to an absolute path
  inside the root. Refuses anything that escapes it, including through `..`,
  and a symlink at the final path.
  """
  @spec resolve(Path.t()) :: {:ok, Path.t()} | {:error, :path_traversal_attempt}
  def resolve(path) when is_binary(path) do
    base = Path.expand(root())
    absolute = Path.expand(path, base)

    if inside?(absolute, base) and not symlink?(absolute) do
      {:ok, absolute}
    else
      {:error, :path_traversal_attempt}
    end
  end

  @doc """
  Moves `source` into `dest_dir` (inside the root) as `filename`, creating the
  directory owner- and group-only. Returns the file name as stored.

  The move is a rename where the two paths share a file system, and a copy
  followed by removing the source otherwise.
  """
  @spec store_atomically(Path.t(), Path.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_atomically(source, dest_dir, filename, context) do
    with {:ok, dir} <- resolve(dest_dir),
         :ok <- ensure_directory(dir),
         name = sanitize_filename(filename),
         :ok <- move(source, Path.join(dir, name), context) do
      {:ok, name}
    end
  end

  @doc """
  Deletes the file at `path` (relative to the root, or absolute inside it).

  One attempt; a file already gone counts as deleted. A failure is reported
  to the operator (`Tymeslot.Infrastructure.AdminAlerts`), since nothing else
  will come back for the file, and returned, never raised, so a caller
  cleaning up after a successful write can ignore it.
  """
  @spec delete_safely(Path.t(), map()) :: :ok | {:error, term()}
  def delete_safely(path, context) do
    with {:ok, absolute} <- resolve(path),
         :ok <- File.rm(absolute) do
      Logger.info("Upload deleted", file_path: absolute, context: context)
      :ok
    else
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Upload delete failed", file_path: path, reason: reason, context: context)

        AdminAlerts.report(:upload_delete_failed,
          summary: "An uploaded file could not be deleted",
          reason: reason,
          context: Map.put(context, :file_path, path)
        )

        {:error, reason}
    end
  end

  defp inside?(path, base), do: path == base or String.starts_with?(path, base <> "/")

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp ensure_directory(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        restrict_directory(dir)

      {:error, reason} ->
        Logger.error("Failed to create upload directory", dir_path: dir, reason: reason)
        {:error, reason}
    end
  end

  # A permissions failure leaves the directory usable, so it is logged only.
  defp restrict_directory(dir) do
    with {:error, reason} <- File.chmod(dir, @directory_mode) do
      Logger.warning("Failed to restrict upload directory", dir_path: dir, reason: reason)
    end

    :ok
  end

  # Names are server-chosen; this is the backstop against a caller passing
  # anything else.
  defp sanitize_filename(filename) do
    case filename
         |> Path.basename()
         |> String.replace(~r/[^\w\-.()]/, "_")
         |> String.slice(0, 255) do
      name when name in ["", ".", ".."] -> stored_name(".bin")
      name -> name
    end
  end

  defp move(source, dest, context) do
    case File.rename(source, dest) do
      :ok -> :ok
      {:error, _cross_device} -> copy_then_remove(source, dest, context)
    end
  end

  defp copy_then_remove(source, dest, context) do
    case File.cp(source, dest) do
      :ok ->
        _removed = File.rm(source)
        :ok

      {:error, reason} ->
        Logger.error("Upload store failed",
          source: source,
          destination: dest,
          reason: reason,
          context: context
        )

        {:error, reason}
    end
  end
end
