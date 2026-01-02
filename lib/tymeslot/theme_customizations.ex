defmodule Tymeslot.ThemeCustomizations do
  @moduledoc """
  The ThemeCustomizations context for managing user theme customizations.
  Main orchestrator that coordinates between functional submodules and handles I/O operations.
  """

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.ThemeCustomizationQueries
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias TymeslotWeb.Helpers.UploadHandler

  # Functional submodules
  alias __MODULE__.{Defaults, Presets, Backgrounds, DataTransform, Validation, Storage}

  @type profile_id :: pos_integer()
  @type theme_id :: String.t()
  @type user_id :: pos_integer()
  @type customization_input :: ThemeCustomizationSchema.t() | map() | nil
  @type upload_attrs :: %{path: String.t(), filename: String.t()}
  @type persistence_result :: {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}
  @type cleanup_entry :: %{
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil
        }

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(profile_id(), theme_id()) ::
          ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    ThemeCustomizationQueries.get_by_profile_and_theme(profile_id, theme_id)
  end

  @doc """
  Gets all theme customizations for a profile.
  """
  @spec get_all_by_profile_id(profile_id()) :: [ThemeCustomizationSchema.t()]
  def get_all_by_profile_id(profile_id) do
    ThemeCustomizationQueries.get_all_by_profile_id(profile_id)
  end

  @doc """
  Creates or updates a theme customization for a profile and theme.
  """
  @spec upsert_theme_customization(profile_id(), theme_id(), map()) ::
          persistence_result()
  def upsert_theme_customization(profile_id, theme_id, attrs) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil ->
        create_theme_customization(profile_id, theme_id, attrs)

      customization ->
        update_theme_customization(customization, attrs)
    end
  end

  @doc """
  Creates a theme customization for a profile and theme.
  """
  @spec create_theme_customization(profile_id(), theme_id(), map()) :: persistence_result()
  def create_theme_customization(profile_id, theme_id, attrs) do
    attrs =
      attrs
      |> Map.put("profile_id", profile_id)
      |> Map.put("theme_id", theme_id)

    # Create the customization (no need to update profile flag anymore)
    ThemeCustomizationQueries.create(attrs)
  end

  @doc """
  Updates a theme customization using the unified upload system.
  """
  @spec update_theme_customization(ThemeCustomizationSchema.t(), map()) ::
          persistence_result()
  def update_theme_customization(%ThemeCustomizationSchema{} = customization, attrs) do
    # Track old files for cleanup
    old_image_path = customization.background_image_path
    old_video_path = customization.background_video_path
    new_image_path = Map.get(attrs, "background_image_path")
    new_video_path = Map.get(attrs, "background_video_path")

    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_update"
    }

    # Perform the atomic database update
    case ThemeCustomizationQueries.update(customization, attrs) do
      {:ok, updated} ->
        # Success: cleanup old files if they were replaced
        if old_image_path && new_image_path && old_image_path != new_image_path do
          old_file_path = Storage.build_theme_file_path(old_image_path)

          UploadHandler.delete_file_safely(
            old_file_path,
            Map.put(context, :file_type, "old_image")
          )
        end

        if old_video_path && new_video_path && old_video_path != new_video_path do
          old_file_path = Storage.build_theme_file_path(old_video_path)

          UploadHandler.delete_file_safely(
            old_file_path,
            Map.put(context, :file_type, "old_video")
          )
        end

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Deletes a theme customization.
  """
  @spec delete_theme_customization(ThemeCustomizationSchema.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}
  def delete_theme_customization(%ThemeCustomizationSchema{} = customization) do
    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_delete"
    }

    # Delete database record first
    case ThemeCustomizationQueries.delete(customization) do
      {:ok, deleted} ->
        # Then cleanup files if they exist
        if customization.background_image_path do
          file_path = Storage.build_theme_file_path(customization.background_image_path)
          UploadHandler.delete_file_safely(file_path, Map.put(context, :file_type, "image"))
        end

        if customization.background_video_path do
          file_path = Storage.build_theme_file_path(customization.background_video_path)
          UploadHandler.delete_file_safely(file_path, Map.put(context, :file_type, "video"))
        end

        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Resets theme customization to defaults for a specific theme.
  """
  @spec reset_to_defaults(profile_id(), theme_id()) ::
          {:ok, ThemeCustomizationSchema.t() | :no_customization} | {:error, Changeset.t()}
  def reset_to_defaults(profile_id, theme_id) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil -> {:ok, :no_customization}
      customization -> delete_theme_customization(customization)
    end
  end

  @doc """
  Gets the CSS variables for a color scheme.
  """
  @spec get_color_scheme_css(String.t() | atom()) :: String.t() | nil
  def get_color_scheme_css(color_scheme) do
    case Presets.find_preset_by_id(:color_scheme, color_scheme) do
      nil ->
        nil

      %{colors: colors} ->
        Enum.map_join(colors, "\n", fn {key, value} ->
          "--theme-#{String.replace(to_string(key), "_", "-")}: #{value};"
        end)
    end
  end

  @doc """
  Gets the CSS for a gradient preset.
  """
  @spec get_gradient_css(String.t() | atom()) :: String.t() | nil
  def get_gradient_css(gradient_id) do
    case Presets.find_preset_by_id(:gradient, gradient_id) do
      nil -> nil
      %{value: value} -> value
    end
  end

  @doc """
  Converts a theme customization schema to a map for use in capability-based customization.
  """
  @spec to_map(customization_input()) :: map()
  def to_map(customization) do
    DataTransform.convert_to_map(customization)
  end

  @doc """
  Gets default customization values for a theme based on capabilities.
  """
  @spec get_defaults(theme_id()) :: map()
  def get_defaults(theme_id) do
    alias TymeslotWeb.Themes.Shared.Customization.Capability
    Capability.get_capability_defaults(theme_id)
  end

  @doc """
  Generates the full theme CSS variables string (capability-based + legacy fallback)
  for a given theme and customization.
  """
  @spec generate_theme_css(theme_id(), customization_input()) :: String.t()
  def generate_theme_css(theme_id, customization) do
    alias TymeslotWeb.Themes.Shared.Customization.Capability
    alias TymeslotWeb.Themes.Shared.Customization.Helpers

    customization_map = to_map(customization)

    capability_css = Capability.generate_css(theme_id, customization_map)

    fallback_css =
      case customization do
        %ThemeCustomizationSchema{} = schema -> Helpers.generate_custom_css(schema)
        _ -> ""
      end

    [capability_css, fallback_css]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n")
  end

  # New orchestrator functions for component interface

  @doc """
  Initializes customization data for the component.
  Returns all data needed for component initialization.
  """
  @spec initialize_customization(profile_id(), theme_id()) :: %{
          customization: ThemeCustomizationSchema.t(),
          original: ThemeCustomizationSchema.t(),
          presets: map(),
          defaults: map()
        }
  def initialize_customization(profile_id, theme_id) do
    saved = get_by_profile_and_theme(profile_id, theme_id)
    customization = Defaults.build_initial_customization(profile_id, theme_id, saved)

    %{
      customization: customization,
      original: saved || customization,
      presets: Presets.get_all_presets(),
      defaults: Defaults.get_theme_defaults(theme_id)
    }
  end

  @doc """
  Applies a color scheme change through the component interface.
  """
  @spec apply_color_scheme_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t() | atom()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, term()}
  def apply_color_scheme_change(profile_id, theme_id, current_customization, scheme_id) do
    with :ok <- Validation.validate_color_scheme(scheme_id),
         new_customization <-
           DataTransform.merge_customization_changes(current_customization, %{
             color_scheme: scheme_id
           }),
         save_attrs <- DataTransform.extract_save_attributes(new_customization) do
      upsert_theme_customization(profile_id, theme_id, save_attrs)
    end
  end

  # Backward-compatible wrapper (to be removed after callers migrate)
  @spec apply_color_scheme_change(map(), String.t() | atom()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, term()}
  def apply_color_scheme_change(socket_assigns, scheme_id) do
    profile_id = socket_assigns.profile.id
    theme_id = socket_assigns.theme_id
    current_customization = socket_assigns.customization

    apply_color_scheme_change(profile_id, theme_id, current_customization, scheme_id)
  end

  @doc """
  Applies a background change through the component interface.
  """
  @spec apply_background_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t(),
          String.t() | nil
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, term()}
  def apply_background_change(profile_id, theme_id, current_customization, type, value) do
    presets = Presets.get_all_presets()

    with :ok <- Validation.validate_background_selection(type, value, presets),
         new_customization <-
           Backgrounds.apply_background_selection(current_customization, type, value),
         cleanup_files <-
           Backgrounds.determine_cleanup_files(current_customization, new_customization),
         save_attrs <- DataTransform.extract_save_attributes(new_customization),
         {:ok, saved} <- upsert_theme_customization(profile_id, theme_id, save_attrs) do
      # Handle file cleanup
      Enum.each(cleanup_files, &cleanup_old_backgrounds/1)

      {:ok, saved}
    end
  end

  # Backward-compatible wrapper (to be removed after callers migrate)
  @spec apply_background_change(map(), String.t(), String.t() | nil) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, term()}
  def apply_background_change(socket_assigns, type, value) do
    profile_id = socket_assigns.profile.id
    theme_id = socket_assigns.theme_id
    current_customization = socket_assigns.customization

    apply_background_change(profile_id, theme_id, current_customization, type, value)
  end

  @doc """
  Gets background description for display in the component.
  """
  @spec get_background_description(ThemeCustomizationSchema.t() | map()) :: String.t()
  def get_background_description(customization) do
    presets = Presets.get_all_presets()
    Backgrounds.generate_background_description(customization, presets)
  end

  @doc """
  Gets CSS value for a background configuration.
  """
  @spec get_background_css(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  def get_background_css(customization) do
    presets = Presets.get_all_presets()
    Backgrounds.get_background_css(customization, presets)
  end

  @doc """
  Gets a theme customization for a user, falling back to defaults.
  """
  @spec get_for_user(user_id(), theme_id()) :: ThemeCustomizationSchema.t() | nil
  def get_for_user(user_id, theme_id) do
    profile = get_profile_by_user_id(user_id)

    case profile do
      nil -> nil
      profile -> get_by_profile_and_theme(profile.id, theme_id)
    end
  end

  # Helper to get profile by user_id
  @spec get_profile_by_user_id(user_id()) :: ProfileSchema.t() | nil
  defp get_profile_by_user_id(user_id) do
    ThemeCustomizationQueries.get_profile_by_user_id(user_id)
  end

  @doc """
  Stores a background image for a profile and theme.
  """
  @spec store_background_image(profile_id(), theme_id(), upload_attrs()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_image(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    Storage.store_background_image(profile_id, theme_id, %{path: temp_path, filename: filename})
  end

  @doc """
  Stores a background video for a profile and theme.
  """
  @spec store_background_video(profile_id(), theme_id(), upload_attrs()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_video(profile_id, theme_id, %{path: temp_path, filename: filename}) do
    Storage.store_background_video(profile_id, theme_id, %{path: temp_path, filename: filename})
  end

  @doc """
  Legacy cleanup function - now delegates to unified system.
  """
  @spec cleanup_old_backgrounds(cleanup_entry() | ThemeCustomizationSchema.t()) :: :ok
  def cleanup_old_backgrounds(customization) do
    context = %{operation: "legacy_cleanup"}

    # Cleanup image if exists
    if image_path = Map.get(customization, :background_image_path) do
      file_path = Storage.build_theme_file_path(image_path)
      UploadHandler.delete_file_safely(file_path, Map.put(context, :file_type, "image"))
    end

    # Cleanup video if exists
    if video_path = Map.get(customization, :background_video_path) do
      file_path = Storage.build_theme_file_path(video_path)
      UploadHandler.delete_file_safely(file_path, Map.put(context, :file_type, "video"))
    end

    :ok
  end

  # Private functions
end
