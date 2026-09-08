defmodule Tymeslot.ThemeCustomizations.Validation do
  @moduledoc """
  Pure validation functions for theme customizations.
  Handles validation of color schemes, background types, values, and file inputs.
  """

  require Logger

  alias Tymeslot.ThemeCustomizations.Presets
  alias TymeslotWeb.Helpers.UploadConstraints

  @valid_background_types ~w(gradient color image video)
  # CSS `#RGB`, `#RRGGBB`, `#RRGGBBAA` — 3, 6 or 8 hex digits, case-insensitive.
  @valid_hex_color_regex ~r/^#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/

  # Tokens that, if present in generated theme CSS, indicate a `</style>` break-out
  # or loader-based injection. Match case-insensitively — attackers try `</STYLE>`,
  # mixed-case `JavaScript:` etc.
  @css_breakout_patterns [
    ~r/<\s*\/\s*style/i,
    ~r/@\s*import/i,
    ~r/expression\s*\(/i,
    ~r/javascript\s*:/i,
    ~r/url\s*\(\s*["']?\s*data:/i
  ]
  @type validation_result :: :ok | {:error, String.t()}
  @type scheme_id :: String.t() | atom()
  @type background_type :: String.t()
  @type background_value :: String.t() | nil
  @type file_kind :: :image | :video
  @type presets_map :: Presets.all_presets()

  @doc """
  Validates a color scheme selection.
  """
  @spec validate_color_scheme(scheme_id(), %{String.t() => term()}) :: validation_result()
  def validate_color_scheme(scheme_id, available_schemes) do
    if Map.has_key?(available_schemes, scheme_id) do
      :ok
    else
      {:error, "Invalid color scheme: #{scheme_id}"}
    end
  end

  @doc """
  Validates a color scheme ID against all available schemes.
  """
  @spec validate_color_scheme(scheme_id()) :: validation_result()
  def validate_color_scheme(scheme_id) do
    validate_color_scheme(scheme_id, Presets.get_color_schemes())
  end

  @doc """
  Validates a background type.
  """
  @spec validate_background_type(background_type()) :: validation_result()
  def validate_background_type(type) when type in @valid_background_types, do: :ok

  def validate_background_type(type) do
    {:error,
     "Invalid background type: #{type}. Must be one of: #{Enum.join(@valid_background_types, ", ")}"}
  end

  @doc """
  Validates a background value based on its type.
  """
  @spec validate_background_value(background_type(), background_value(), presets_map()) ::
          validation_result()
  def validate_background_value("gradient", value, presets) do
    gradients = Map.get(presets, :gradients, %{})

    if Map.has_key?(gradients, value) do
      :ok
    else
      {:error, "Invalid gradient preset: #{value}"}
    end
  end

  def validate_background_value("color", value, _presets) do
    validate_hex_color(value)
  end

  def validate_background_value("image", "custom", _presets), do: :ok

  def validate_background_value("image", value, presets) do
    images = Map.get(presets, :images, %{})

    if Map.has_key?(images, value) do
      :ok
    else
      {:error, "Invalid image preset: #{value}"}
    end
  end

  def validate_background_value("video", "custom", _presets), do: :ok

  def validate_background_value("video", value, presets) do
    videos = Map.get(presets, :videos, %{})

    if Map.has_key?(videos, value) do
      :ok
    else
      {:error, "Invalid video preset: #{value}"}
    end
  end

  def validate_background_value(type, value, _available_presets) do
    {:error, "Invalid background value '#{value}' for type '#{type}'"}
  end

  @doc """
  Validates a complete background selection (type + value).
  """
  @spec validate_background_selection(background_type(), background_value(), presets_map()) ::
          validation_result()
  def validate_background_selection(type, value, presets) do
    with :ok <- validate_background_type(type) do
      validate_background_value(type, value, presets)
    end
  end

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
  Validates a hex color value.

  Accepts the three CSS hex-colour shapes — `#RGB`, `#RRGGBB`, `#RRGGBBAA` —
  case-insensitively, with surrounding whitespace trimmed.
  """
  @spec validate_hex_color(term()) :: validation_result()
  def validate_hex_color(color) when is_binary(color) do
    if Regex.match?(@valid_hex_color_regex, String.trim(color)) do
      :ok
    else
      {:error, "Invalid hex color format. Must be #RGB, #RRGGBB or #RRGGBBAA"}
    end
  end

  def validate_hex_color(_value), do: {:error, "Color must be a string"}

  @doc """
  Defence-in-depth filter for generated theme CSS.

  The individual validators above already restrict each field, but this runs
  at the output boundary so that — even if a new customisation field is added
  and forgets its own validator — a payload that tries to break out of the
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
      type: inspect(other)
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
