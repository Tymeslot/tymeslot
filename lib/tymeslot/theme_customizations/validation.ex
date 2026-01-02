defmodule Tymeslot.ThemeCustomizations.Validation do
  @moduledoc """
  Pure validation functions for theme customizations.
  Handles validation of color schemes, background types, values, and file inputs.
  """

  alias Tymeslot.ThemeCustomizations.Presets

  @valid_background_types ~w(gradient color image video)
  @valid_hex_color_regex ~r/^#[0-9A-Fa-f]{6}$/
  @type validation_result :: :ok | {:error, String.t()}
  @type scheme_id :: String.t() | atom()
  @type background_type :: String.t()
  @type background_value :: String.t() | nil
  @type field_error :: {atom(), String.t()}
  @type field_errors :: [field_error()]
  @type file_kind :: :image | :video
  @type file_upload_params :: %{
          required(:path) => Path.t(),
          required(:filename) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  Validates a color scheme selection.
  """
  @spec validate_color_scheme(scheme_id(), map()) :: validation_result()
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
  @spec validate_background_value(background_type(), background_value(), map()) ::
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

  def validate_background_value(type, value, _presets) do
    {:error, "Invalid background value '#{value}' for type '#{type}'"}
  end

  @doc """
  Validates a complete background selection (type + value).
  """
  @spec validate_background_selection(background_type(), background_value(), map()) ::
          validation_result()
  def validate_background_selection(type, value, presets) do
    with :ok <- validate_background_type(type) do
      validate_background_value(type, value, presets)
    end
  end

  @doc """
  Validates customization change attributes.
  """
  @spec validate_customization_changes(map()) :: :ok | {:error, field_errors()}
  def validate_customization_changes(changes) do
    errors = []

    # Validate color scheme if present
    errors =
      case Map.get(changes, :color_scheme) do
        nil ->
          errors

        scheme ->
          validate_field_and_collect_error(
            errors,
            :color_scheme,
            &validate_color_scheme/1,
            scheme
          )
      end

    # Validate background type if present
    errors =
      case Map.get(changes, :background_type) do
        nil ->
          errors

        type ->
          validate_field_and_collect_error(
            errors,
            :background_type,
            &validate_background_type/1,
            type
          )
      end

    # Return validation result
    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  Sanitizes customization input attributes.
  """
  @spec sanitize_customization_input(term()) :: {:ok, map()} | {:error, String.t()}
  def sanitize_customization_input(attrs) when is_map(attrs) do
    attrs
    |> sanitize_string_fields()
    |> validate_required_fields()
  end

  def sanitize_customization_input(_attrs), do: {:error, "Attributes must be a map"}

  @doc """
  Validates a hex color value.
  """
  @spec validate_hex_color(term()) :: validation_result()
  def validate_hex_color(color) when is_binary(color) do
    if Regex.match?(@valid_hex_color_regex, color) do
      :ok
    else
      {:error, "Invalid hex color format. Must be #RRGGBB"}
    end
  end

  def validate_hex_color(_), do: {:error, "Color must be a string"}

  @doc """
  Validates file upload parameters.
  """
  @spec validate_file_upload(file_upload_params() | term()) :: validation_result()
  def validate_file_upload(%{path: path, filename: filename})
      when is_binary(path) and is_binary(filename) do
    cond do
      not File.exists?(path) ->
        {:error, "Uploaded file does not exist"}

      String.trim(filename) == "" ->
        {:error, "Filename cannot be empty"}

      true ->
        :ok
    end
  end

  def validate_file_upload(_), do: {:error, "Invalid file upload parameters"}

  @doc """
  Validates that a file extension is allowed for the given type.
  """
  @spec validate_file_extension(String.t(), file_kind() | atom()) :: validation_result()
  def validate_file_extension(filename, :image) do
    allowed_extensions = ~w(.jpg .jpeg .png .gif .webp)
    extension = String.downcase(Path.extname(filename))

    if extension in allowed_extensions do
      :ok
    else
      {:error, "Invalid image file extension. Allowed: #{Enum.join(allowed_extensions, ", ")}"}
    end
  end

  def validate_file_extension(filename, :video) do
    allowed_extensions = ~w(.mp4 .webm .mov .avi)
    extension = String.downcase(Path.extname(filename))

    if extension in allowed_extensions do
      :ok
    else
      {:error, "Invalid video file extension. Allowed: #{Enum.join(allowed_extensions, ", ")}"}
    end
  end

  def validate_file_extension(_, type), do: {:error, "Unknown file type: #{type}"}

  @doc """
  Validates file size limits.
  """
  @spec validate_file_size(Path.t(), file_kind()) :: validation_result()
  def validate_file_size(file_path, :image) do
    # 10MB
    max_size = 10 * 1024 * 1024
    validate_file_size_limit(file_path, max_size, "Image")
  end

  def validate_file_size(file_path, :video) do
    # 100MB
    max_size = 100 * 1024 * 1024
    validate_file_size_limit(file_path, max_size, "Video")
  end

  # Private helper functions

  defp validate_field_and_collect_error(errors, field, validator, value) do
    case validator.(value) do
      :ok -> errors
      {:error, message} -> [{field, message} | errors]
    end
  end

  defp sanitize_string_fields(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(value) ->
        Map.put(acc, key, String.trim(value))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp validate_required_fields(attrs) do
    # For now, no fields are strictly required during updates
    # This can be extended based on business rules
    {:ok, attrs}
  end

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
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)}MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)}KB"
      true -> "#{bytes}B"
    end
  end
end
