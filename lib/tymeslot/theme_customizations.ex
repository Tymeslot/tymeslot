defmodule Tymeslot.ThemeCustomizations do
  @moduledoc """
  The ThemeCustomizations context for managing user theme customizations.
  Main orchestrator that coordinates between functional submodules and handles I/O operations.
  """

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  # Functional submodules
  alias __MODULE__.{
    Backgrounds,
    Capability,
    Css,
    DataTransform,
    Defaults,
    FileLifecycle,
    Presets,
    Storage,
    Validation
  }

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
  Returns a random video-background preset key (e.g. `"preset:blue-wave"`).

  Used to seed a fresh account with a moving background so its booking page —
  and the onboarding preview of it — has life out of the box.
  """
  @spec random_video_preset() :: String.t()
  def random_video_preset do
    Presets.get_video_presets()
    |> Map.keys()
    |> Enum.random()
  end

  @doc """
  Creates or updates a theme customization for a profile and theme.
  """
  @spec upsert_theme_customization(profile_id(), theme_id(), map()) ::
          persistence_result()
  def upsert_theme_customization(profile_id, theme_id, attrs) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil ->
        # Create with required defaults if not present
        create_attrs =
          Map.merge(
            %{
              "color_scheme" => "default",
              "background_type" => "gradient",
              "background_value" => "gradient_1"
            },
            attrs
          )

        create_theme_customization(profile_id, theme_id, create_attrs)

      customization ->
        # Update only the provided fields
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

    # Create the customization with race condition handling
    case ThemeCustomizationQueries.create(attrs) do
      {:ok, result} ->
        {:ok, result}

      {:error, changeset} ->
        # If we hit a unique constraint, it means another request created it concurrently.
        # In this case, we should update the existing record instead.
        if has_unique_constraint_error?(changeset) do
          case get_by_profile_and_theme(profile_id, theme_id) do
            # Should not happen if constraint violated
            nil -> {:error, changeset}
            customization -> update_theme_customization(customization, attrs)
          end
        else
          {:error, changeset}
        end
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field == :profile_id and Keyword.get(opts, :constraint) == :unique
    end)
  end

  @doc """
  Updates a theme customization using the unified upload system.
  """
  @spec update_theme_customization(ThemeCustomizationSchema.t(), map()) ::
          persistence_result()
  def update_theme_customization(%ThemeCustomizationSchema{} = customization, attrs) do
    # Perform the atomic database update, then cleanup replaced files on success
    case ThemeCustomizationQueries.update(customization, attrs) do
      {:ok, updated} ->
        FileLifecycle.cleanup_replaced_files(customization, attrs)
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
    # Delete database record first, then cleanup files on success
    case ThemeCustomizationQueries.delete(customization) do
      {:ok, deleted} ->
        FileLifecycle.cleanup_all_files(customization)
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

  Accepts either a scheme ID (string/atom — looked up in the static preset map)
  or a customisation map. The map form supports the "custom" scheme: when
  `color_scheme == "custom"`, the palette is derived from `custom_palette_seed`
  via `PaletteDerivation.derive_palette/1` instead of preset lookup.
  """
  @spec get_color_scheme_css(String.t() | atom() | map()) :: String.t() | nil
  defdelegate get_color_scheme_css(customization), to: Css

  @doc """
  Gets the CSS for a gradient preset.
  """
  @spec get_gradient_css(String.t() | atom()) :: String.t() | nil
  defdelegate get_gradient_css(gradient_id), to: Css

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
    Capability.get_capability_defaults(theme_id)
  end

  @doc """
  Generates the full theme CSS variables string (capability-based + legacy fallback)
  for a given theme and customization.
  """
  @spec generate_theme_css(theme_id(), customization_input()) :: String.t()
  def generate_theme_css(theme_id, customization) do
    Css.generate_theme_css(theme_id, to_map(customization))
  end

  # New orchestrator functions for component interface

  @doc """
  Initializes customization data for the component.
  Returns all data needed for component initialization.
  """
  @spec initialize_customization(profile_id(), theme_id()) :: %{
          customization: ThemeCustomizationSchema.t(),
          original: ThemeCustomizationSchema.t(),
          presets: map()
        }
  def initialize_customization(profile_id, theme_id) do
    saved = get_by_profile_and_theme(profile_id, theme_id)
    customization = Defaults.build_initial_customization(profile_id, theme_id, saved)

    %{
      customization: customization,
      original: saved || customization,
      presets: Presets.get_all_presets()
    }
  end

  @default_custom_palette_seed "#06b6d4"

  @doc """
  Returns the brand default seed hex used when a user first activates the
  custom-palette mode and has no previously stored seed.
  """
  @spec default_custom_palette_seed() :: String.t()
  def default_custom_palette_seed, do: @default_custom_palette_seed

  @doc """
  Resolves the active colour scheme for a customization, returning the same
  `%{name, colors}` shape used by both presets and palette derivation.

  When `custom_palette_seed` is present on the customization, the palette is
  derived from that seed; otherwise the `color_scheme` field is looked up in
  the provided `presets.color_schemes` map.  Returns `nil` if neither resolves
  to a known scheme.
  """
  @spec resolve_active_scheme(ThemeCustomizationSchema.t() | map(), map()) :: map() | nil
  defdelegate resolve_active_scheme(customization, presets), to: Css

  @doc """
  Applies a color scheme change through the component interface.

  Switching to the "custom" scheme reuses the existing seed if one is already
  stored; otherwise it seeds with the brand turquoise default. Use
  `apply_custom_palette_change/4` directly when the user picks a specific
  custom seed.
  """
  @spec apply_color_scheme_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t() | atom()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_color_scheme_change(profile_id, theme_id, current_customization, "custom") do
    seed = Css.get_seed(current_customization) || @default_custom_palette_seed
    apply_custom_palette_change(profile_id, theme_id, current_customization, seed)
  end

  def apply_color_scheme_change(profile_id, theme_id, current_customization, scheme_id) do
    with :ok <- Validation.validate_color_scheme(scheme_id),
         :ok <- validate_theme_capability(theme_id, %{"color_scheme" => scheme_id}),
         new_customization <-
           DataTransform.merge_customization_changes(current_customization, %{
             color_scheme: scheme_id,
             custom_palette_seed: nil
           }),
         save_attrs <- DataTransform.extract_save_attributes(new_customization) do
      profile_id
      |> upsert_theme_customization(theme_id, save_attrs)
      |> format_persistence_error()
    end
  end

  # Backward-compatible wrapper (to be removed after callers migrate)
  @spec apply_color_scheme_change(map(), String.t() | atom()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_color_scheme_change(socket_assigns, scheme_id) do
    profile_id = socket_assigns.profile.id
    theme_id = socket_assigns.theme_id
    current_customization = socket_assigns.customization

    apply_color_scheme_change(profile_id, theme_id, current_customization, scheme_id)
  end

  @doc """
  Switches the customisation to the "custom" colour scheme and persists the seed
  hex used to derive the palette.

  The seed must be a 6-character hex string (with leading `#`); otherwise an
  error is returned without touching the database.
  """
  @spec apply_custom_palette_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_custom_palette_change(profile_id, theme_id, current_customization, seed_hex) do
    with :ok <- Css.validate_seed_hex(seed_hex),
         new_customization <-
           DataTransform.merge_customization_changes(current_customization, %{
             custom_palette_seed: String.downcase(seed_hex)
           }),
         save_attrs <- DataTransform.extract_save_attributes(new_customization) do
      profile_id
      |> upsert_theme_customization(theme_id, save_attrs)
      |> format_persistence_error()
    end
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
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_background_change(profile_id, theme_id, current_customization, type, value) do
    presets = Presets.get_all_presets()

    with :ok <- Validation.validate_background_selection(type, value, presets),
         :ok <- validate_theme_capability(theme_id, %{"background_type" => type}),
         new_customization <-
           Backgrounds.apply_background_selection(current_customization, type, value),
         cleanup_files <-
           Backgrounds.determine_cleanup_files(current_customization, new_customization),
         save_attrs <- DataTransform.extract_save_attributes(new_customization),
         {:ok, saved} <-
           profile_id
           |> upsert_theme_customization(theme_id, save_attrs)
           |> format_persistence_error() do
      Enum.each(cleanup_files, &FileLifecycle.cleanup_old_backgrounds/1)

      {:ok, saved}
    end
  end

  # Backward-compatible wrapper (to be removed after callers migrate)
  @spec apply_background_change(map(), String.t(), String.t() | nil) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
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
  defdelegate cleanup_old_backgrounds(customization), to: FileLifecycle

  # Private functions

  defp validate_theme_capability(theme_id, attrs) do
    case Capability.validate_customization(theme_id, attrs) do
      {:ok, _attrs} -> :ok
      {:error, reasons} -> {:error, Enum.join(reasons, "; ")}
    end
  end

  # Converts unexpected changeset errors from persistence into a user-safe
  # string. Callers flash the returned message, and `Flash.error/1` guards on
  # binaries — a raw changeset would crash the component.
  @spec format_persistence_error(persistence_result()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defp format_persistence_error({:ok, _result} = ok), do: ok

  defp format_persistence_error({:error, %Changeset{}}),
    do: {:error, "Could not save your theme customization. Please try again."}
end
