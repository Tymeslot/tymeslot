defmodule Tymeslot.Emails.Branding do
  @moduledoc """
  Instance-level branding applied to outgoing transactional email.

  A self-hosted instance can replace the logo that heads every email, the
  name substituted into user-facing copy, and the brand accent. All three are
  admin-editable settings (see `Tymeslot.AppSettings`), written only through
  the admin UI, which requires an admin role.

  The footer attribution is deliberately not configurable here.

  ## Logo storage

  Logos are normalised to PNG before they reach this module — the admin UI
  rasterises whatever the admin picked, so an SVG or WebP source still lands
  as a PNG. The uploaded file is moved under `branding/` inside the
  configured `:upload_directory`, the same volume-backed location as avatars
  and theme backgrounds, so a logo survives a container rebuild.

  Only the path *relative to* the upload directory is stored. An absolute
  path would break the moment the deployment type changed the upload root,
  and it would put a filesystem path from user input into a column that later
  feeds `File.read/1`.

  Each stored file gets a random suffix. The admin preview is served from
  `/uploads`, and reusing one filename would leave browsers showing the
  previous logo from cache after a replacement.
  """

  alias Tymeslot.AppSettings
  alias Tymeslot.Utils.Colour
  alias Tymeslot.Utils.MediaValidator
  alias TymeslotWeb.Helpers.FileOperations
  alias TymeslotWeb.Helpers.UploadHandler

  require Logger

  @logo_dir "branding"
  @logo_extension ".png"
  @random_suffix_bytes 8

  @stock_logo_path "priv/static/images/brand/logo-with-text.png"

  # WCAG 2.1 minimum for the button's white text: it renders at
  # `Styles.font_size(:md)` (16px) with `font-weight="700"`, which does not
  # meet the 14pt-bold/18pt-regular "large text" carve-out, so the normal-text
  # threshold applies rather than the 3.0 used for genuinely large/bold text
  # (see `BrandPalette.@band_min_contrast`).
  @button_min_contrast 4.5

  # The hand-tuned turquoise family that applies when no accent is configured,
  # or when a configured seed fails to derive. Which colour ships by default is
  # a branding fact, so it lives here beside the other defaults rather than in
  # the styles tree that derives against it.
  #
  # `deep` clears the same 4.5:1 floor against band text that
  # `BrandPalette.@band_min_contrast` clamps *derived* families to, so a
  # self-hosted instance's custom brand band is never held to a stricter bar
  # than Tymeslot's own default one.
  @stock_family %{accent: "#14b8a6", deep: "#0d786c", ink: "#0f5954", tint: "#e1f7f3"}

  @doc """
  The brand name substituted into email copy: the logo's alt text, the inbox
  preview line, the document title, and the organiser strip's fallback title.

  Never returns nil — an instance that has not set one gets "Tymeslot".
  """
  @spec brand_name() :: String.t()
  def brand_name, do: AppSettings.get(:email_brand_name)

  @doc """
  The configured brand accent as a normalised hex string, or `nil` when the
  instance has not set one and the stock turquoise applies.
  """
  @spec accent() :: String.t() | nil
  def accent, do: AppSettings.get(:email_brand_accent)

  @doc """
  The hand-tuned turquoise family emails fall back to when no accent is
  configured, or when a configured one fails to derive.
  """
  @spec stock_family() :: %{
          accent: String.t(),
          deep: String.t(),
          ink: String.t(),
          tint: String.t()
        }
  def stock_family, do: @stock_family

  @doc """
  The accent that ships by default, regardless of whether an instance has
  configured its own.
  """
  @spec stock_accent() :: String.t()
  def stock_accent, do: @stock_family.accent

  @doc """
  Normalises admin input for the brand accent to a lowercase `#rrggbb` hex
  string, or `nil` when the input is not a valid hex colour.
  """
  @spec normalise_accent(String.t() | nil) :: String.t() | nil
  def normalise_accent(hex), do: Colour.normalise_hex(hex)

  @doc """
  Plain preview data for a candidate accent, for the admin UI to render: the
  normalised hex, the contrast ratio of white button text against it, and
  whether that ratio is low enough to warn on. Returns `nil` when `hex` is
  not a valid hex colour.
  """
  @spec accent_preview(String.t() | nil) ::
          %{hex: String.t(), contrast: float(), low_contrast?: boolean()} | nil
  def accent_preview(hex) do
    case normalise_accent(hex) do
      nil ->
        nil

      normalised ->
        contrast = Colour.contrast_ratio("#ffffff", normalised)
        %{hex: normalised, contrast: contrast, low_contrast?: contrast < @button_min_contrast}
    end
  end

  @doc """
  Absolute path to the custom logo, or `nil` when none is configured.

  Returns `nil` rather than raising when the setting points at a file that is
  no longer on disk, so a logo deleted out from under the app degrades to the
  stock logo instead of breaking every outgoing email.
  """
  @spec custom_logo_path() :: String.t() | nil
  def custom_logo_path do
    case configured_logo_relative_path() do
      nil -> nil
      relative -> Path.join(upload_dir(), relative)
    end
  end

  # Shared by `custom_logo_path/0` and `logo_url/0` so both agree on what
  # "configured" means: a setting that both exists and still points at a file
  # on disk. Without this, a logo deleted out from under the app left the
  # admin page showing a broken image and a "Remove" button for a logo that
  # outgoing email had already silently stopped using.
  @spec configured_logo_relative_path() :: String.t() | nil
  defp configured_logo_relative_path do
    case AppSettings.get(:email_logo_path) do
      nil -> nil
      relative -> if logo_on_disk?(relative), do: relative, else: nil
    end
  end

  defp logo_on_disk?(relative) do
    path = Path.join(upload_dir(), relative)

    if File.regular?(path) do
      true
    else
      warn_missing_logo_once(path)
      false
    end
  end

  # This runs on the unconditional per-email path (every template ultimately
  # calls `logo_bytes/0`), so a detached volume or a deleted file must not log
  # once per email — that is one warning-level line, with an absolute
  # filesystem path, per send, forever. Memoised the same way
  # `BrandPalette` memoises its derived family: a `:persistent_term` slot that
  # a changed setting simply replaces, so a genuinely new missing path (a
  # different logo was configured and is also missing) still gets reported.
  @missing_logo_warning_key {__MODULE__, :missing_logo_warned_path}

  defp warn_missing_logo_once(path) do
    if :persistent_term.get(@missing_logo_warning_key, nil) != path do
      Logger.warning("Configured email logo is missing; falling back to the stock logo",
        path: path
      )

      :persistent_term.put(@missing_logo_warning_key, path)
    end

    :ok
  end

  @doc """
  Bytes of the logo to attach to an email: the custom logo when one is
  configured and readable, the stock Tymeslot logo otherwise, and `:error`
  when neither can be read.
  """
  @spec logo_bytes() :: {:ok, binary()} | :error
  def logo_bytes do
    case custom_logo_path() do
      nil -> read_logo(stock_logo_path())
      path -> read_custom_logo(path)
    end
  end

  defp read_custom_logo(path) do
    case read_logo(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        Logger.warning("Custom email logo could not be read; falling back to the stock logo",
          path: path
        )

        read_logo(stock_logo_path())
    end
  end

  defp read_logo(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> :error
    end
  end

  @doc "Absolute path to the logo that ships with the release."
  @spec stock_logo_path() :: String.t()
  def stock_logo_path, do: Application.app_dir(:tymeslot, @stock_logo_path)

  @doc """
  Stores the file at `source_path` as the instance logo and records the new
  path, replacing and deleting any logo already stored.

  The file is validated as a real PNG before anything is written: the admin
  UI converts in the browser, so what arrives here is only as trustworthy as
  the client that sent it.
  """
  @spec store_logo(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def store_logo(source_path) when is_binary(source_path) do
    with true <- MediaValidator.valid_png_file?(source_path),
         previous = AppSettings.get(:email_logo_path),
         {:ok, relative} <- write_logo(source_path),
         {:ok, _settings} <- AppSettings.update(%{email_logo_path: relative}) do
      delete_stored_logo(previous)
      {:ok, relative}
    else
      false -> {:error, :not_a_png}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the configured logo and removes the stored file, restoring the stock
  logo on outgoing email.
  """
  @spec remove_logo() :: :ok | {:error, term()}
  def remove_logo do
    previous = AppSettings.get(:email_logo_path)

    case AppSettings.update(%{email_logo_path: nil}) do
      {:ok, _settings} ->
        delete_stored_logo(previous)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  URL path at which the stored logo is served, for the admin preview, or
  `nil` when no custom logo is configured or the configured file is no longer
  on disk.

  Routes through the same existence check as `custom_logo_path/0`, so the
  admin page never shows a broken image and a "Remove" button for a logo that
  outgoing email has already stopped using.
  """
  @spec logo_url() :: String.t() | nil
  def logo_url do
    case configured_logo_relative_path() do
      nil -> nil
      relative -> "/uploads/" <> relative
    end
  end

  defp write_logo(source_path) do
    dir = Path.join(upload_dir(), @logo_dir)

    case UploadHandler.store_file_atomically(source_path, dir, random_filename(), %{
           context: :email_logo
         }) do
      {:ok, filename} ->
        {:ok, Path.join(@logo_dir, filename)}

      {:error, reason} ->
        Logger.error("Failed to store email logo", reason: inspect(reason))
        {:error, :write_failed}
    end
  end

  defp delete_stored_logo(nil), do: :ok

  defp delete_stored_logo(relative) do
    FileOperations.safe_delete_file(Path.join(upload_dir(), relative), %{context: :email_logo})
  end

  defp random_filename do
    suffix =
      @random_suffix_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "email-logo-#{suffix}#{@logo_extension}"
  end

  defp upload_dir, do: Application.get_env(:tymeslot, :upload_directory, "uploads")
end
