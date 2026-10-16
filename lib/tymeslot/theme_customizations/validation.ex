defmodule Tymeslot.ThemeCustomizations.Validation do
  @moduledoc """
  Path and CSS sanitisation and upload size limits for theme customisations.
  Setting validation lives in each theme's customisation spec.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Media.UploadConstraints

  # Tokens that, if present in generated theme CSS, indicate a `</style>` break-out
  # or loader-based injection. Match case-insensitively: attackers try `</STYLE>`,
  # mixed-case `JavaScript:` etc.
  @css_breakout_patterns [
    ~r/<\s*\/\s*style/i,
    ~r/@\s*import/i,
    ~r/expression\s*\(/i,
    ~r/javascript\s*:/i,
    ~r/url\s*\(\s*["']?\s*data:/i
  ]
  @type validation_result :: :ok | {:error, String.t()}
  @type file_kind :: :image | :video

  @doc """
  Sanitizes a file path to prevent directory traversal and other injection attacks.
  Only allows alphanumeric, dots, dashes, and underscores in each segment.
  """
  @spec sanitize_path(String.t() | nil) :: String.t()
  def sanitize_path(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.map(fn segment ->
      segment
      |> String.replace(~r/[^a-zA-Z0-9\._-]/, "")
      |> String.replace("..", "")
    end)
    |> Enum.filter(&(&1 != "" and &1 != "." and &1 != ".."))
    |> Enum.join("/")
  end

  def sanitize_path(nil), do: ""

  @doc """
  Defence-in-depth filter for generated theme CSS.

  The customisation specs already restrict each field, but this runs
  at the output boundary so that, even if a new customisation field is added
  and forgets its own validator, a payload that tries to break out of the
  surrounding `<style>` tag can never reach the browser. Returns the CSS
  unchanged when safe, or the empty string when any break-out pattern matches.
  """
  @spec sanitize_css(term()) :: String.t()
  def sanitize_css(css) when is_binary(css) do
    if Enum.any?(@css_breakout_patterns, &Regex.match?(&1, css)) do
      Logger.warning("theme custom CSS blocked by sanitize_css breakout pattern",
        css_byte_size: byte_size(css)
      )

      ""
    else
      css
    end
  end

  def sanitize_css(other) do
    Logger.error("theme custom CSS sanitize_css received non-binary input",
      type: LogFormat.reason(other)
    )

    ""
  end

  @doc """
  Validates file size limits.

  The caps come from `UploadConstraints`, which is also what the background
  upload's `allow_upload` enforces at preflight. Restating them here as literals
  is how they last drifted: the video branch capped at 100 MiB while the upload
  refused anything over 100 MB, so a file between the two passed this validator
  and was then rejected by the uploader.
  """
  @spec validate_file_size(Path.t(), file_kind()) :: validation_result()
  def validate_file_size(file_path, :image) do
    validate_file_size_limit(file_path, UploadConstraints.max_file_size(:image), "Image")
  end

  def validate_file_size(file_path, :video) do
    validate_file_size_limit(file_path, UploadConstraints.max_file_size(:video), "Video")
  end

  # Private helper functions

  defp validate_file_size_limit(file_path, max_size, file_type) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size <= max_size ->
        :ok

      {:ok, %{size: size}} ->
        {:error,
         "#{file_type} file too large: #{format_bytes(size)}. Maximum allowed: #{format_bytes(max_size)}"}

      {:error, _reason} ->
        {:error, "Could not determine file size"}
    end
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)}MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)}KB"
      true -> "#{bytes}B"
    end
  end
end
