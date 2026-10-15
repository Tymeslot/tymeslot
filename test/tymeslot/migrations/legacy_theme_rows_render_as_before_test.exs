defmodule Tymeslot.Migrations.LegacyThemeRowsRenderAsBeforeTest do
  @moduledoc """
  A theme customisation saved by the previous release renders after the
  upgrade exactly as it rendered before it.

  The migration tests for `20260929081519_move_theme_customization_options_to_settings`
  and `20261014084423_sync_legacy_theme_columns_into_settings` prove the
  columns reach `settings`; this proves the copied `settings` mean the same
  thing to the booking page. Each case writes a row in the column shape the
  previous release stored, runs the real migrations over it, loads it the
  way the booking page does and resolves its tokens
  (`ThemeCustomizations.tokens/3`).

  The expected values are literals, captured by running the previous
  release's renderer (`Css.generate_theme_css/2` for the custom properties,
  `Customization.Helpers.get_background_style/1`, `VideoSources` and
  `prepare_wrapper_assigns/1` for the background) over the same columns, so
  they cannot move with the code under test. Two differences are by design
  and normalised here: behind an image or a video `--theme-background` is now
  `var(--theme-canvas)`, which resolves to the colour the previous release
  wrote there directly, and the previous release's `--theme-background-image`
  is gone, the image being painted from the background descriptor instead
  (asserted as `media.background`).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.ThemeCustomizations

  @settings_version 20_260_929_081_519
  @sync_version 20_261_014_084_423

  @quill "1"
  @rhythm "2"

  # The columns' own defaults, which every row the previous release wrote
  # carries for what it did not set.
  @column_defaults %{
    color_scheme: "default",
    custom_palette_seed: nil,
    background_type: "gradient",
    background_value: nil,
    background_image_path: nil,
    background_video_path: nil
  }

  @rhythm_default_sources [
    {"/videos/backgrounds/rhythm-background-desktop.webm", "video/webm", "(min-width: 1024px)"},
    {"/videos/backgrounds/rhythm-background-desktop.mp4", "video/mp4", "(min-width: 1024px)"},
    {"/videos/backgrounds/rhythm-background-mobile.mp4", "video/mp4", "(max-width: 768px)"},
    {"/videos/backgrounds/rhythm-background-low.mp4", "video/mp4", "(max-width: 480px)"},
    {"/videos/backgrounds/rhythm-background-original.mp4", "video/mp4", nil}
  ]

  @uploaded_video_sources [
    {"/uploads/7/2/backgrounds/clip-desktop.webm", "video/webm", "(min-width: 1024px)"},
    {"/uploads/7/2/backgrounds/clip-desktop.mp4", "video/mp4", "(min-width: 1024px)"},
    {"/uploads/7/2/backgrounds/clip-mobile.mp4", "video/mp4", "(max-width: 1023px)"},
    {"/uploads/7/2/backgrounds/clip-low.mp4", "video/mp4", "(max-width: 480px)"},
    {"/uploads/7/2/backgrounds/clip.mp4", "video/mp4", nil}
  ]

  # {case, theme, columns the previous release stored, its custom
  # properties, its background}
  @cases [
    {"a custom scheme with a seed", @quill,
     %{color_scheme: "custom", custom_palette_seed: "#3366cc", background_value: "gradient_2"},
     %{
       "--theme-accent" => "#8270db",
       "--theme-accent-solid" => "#8270db",
       "--theme-background" => "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)",
       "--theme-on-accent" => "#0c121d",
       "--theme-on-primary" => "#ffffff",
       "--theme-primary" => "#3366cc",
       "--theme-primary-hover" => "#2b56ab",
       "--theme-primary-solid" => "#3366cc",
       "--theme-primary-solid-hover" => "#2b56ab",
       "--theme-secondary" => "#5d9dcb",
       "--theme-surface" => "rgba(32, 41, 60, 0.5)",
       "--theme-text" => "#e8eaee",
       "--theme-text-secondary" => "#adb4c2"
     }, %{kind: :gradient, css: "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)"}},
    {"an uppercase seed", @rhythm,
     %{
       color_scheme: "custom",
       custom_palette_seed: "#AB34CD",
       background_type: "color",
       background_value: "#112233"
     },
     %{
       "--theme-accent" => "#dc71be",
       "--theme-accent-solid" => "#dc71be",
       "--theme-background" => "#112233",
       "--theme-on-accent" => "#190c1d",
       "--theme-on-primary" => "#ffffff",
       "--theme-primary" => "#ab34cd",
       "--theme-primary-hover" => "#902bad",
       "--theme-primary-solid" => "#ab34cd",
       "--theme-primary-solid-hover" => "#902bad",
       "--theme-secondary" => "#985ecb",
       "--theme-surface" => "rgba(54, 32, 60, 0.5)",
       "--theme-text" => "#ece8ee",
       "--theme-text-secondary" => "#beadc2"
     }, %{kind: :color, color: "#112233"}},
    {"a colour background", @quill,
     %{color_scheme: "ocean", background_type: "color", background_value: "#1a2b3c"},
     %{
       "--theme-accent" => "#7dd3fc",
       "--theme-accent-solid" => "#7dd3fc",
       "--theme-background" => "#1a2b3c",
       "--theme-on-accent" => "#082f49",
       "--theme-on-primary" => "#082f49",
       "--theme-primary" => "#0ea5e9",
       "--theme-primary-hover" => "#0284c7",
       "--theme-primary-solid" => "#0ea5e9",
       "--theme-primary-solid-hover" => "#029fef",
       "--theme-secondary" => "#38bdf8",
       "--theme-surface" => "rgba(12, 74, 110, 0.5)",
       "--theme-text" => "#e0f2fe",
       "--theme-text-secondary" => "#bae6fd"
     }, %{kind: :color, color: "#1a2b3c"}},
    {"a preset image", @quill,
     %{color_scheme: "forest", background_type: "image", background_value: "preset:ocean-sunset"},
     %{
       "--theme-accent" => "#6ee7b7",
       "--theme-accent-solid" => "#6ee7b7",
       "--theme-background" => "#052e16",
       "--theme-on-accent" => "#052e16",
       "--theme-on-primary" => "#052e16",
       "--theme-primary" => "#10b981",
       "--theme-primary-hover" => "#059669",
       "--theme-primary-solid" => "#10b981",
       "--theme-primary-solid-hover" => "#06aa77",
       "--theme-secondary" => "#34d399",
       "--theme-surface" => "rgba(20, 83, 45, 0.5)",
       "--theme-text" => "#d1fae5",
       "--theme-text-secondary" => "#a7f3d0"
     }, %{kind: :image, url: "/images/themes/backgrounds/ocean-sunset.webp"}},
    {"an uploaded image", @quill,
     %{
       color_scheme: "rose",
       background_type: "image",
       background_value: "custom",
       background_image_path: "5/1/backgrounds/photo.webp"
     },
     %{
       "--theme-accent" => "#fda4af",
       "--theme-accent-solid" => "#fda4af",
       "--theme-background" => "#4c0519",
       "--theme-on-accent" => "#4c0519",
       "--theme-on-primary" => "#ffffff",
       "--theme-primary" => "#f43f5e",
       "--theme-primary-hover" => "#e11d48",
       "--theme-primary-solid" => "#e80d33",
       "--theme-primary-solid-hover" => "#e11d48",
       "--theme-secondary" => "#fb7185",
       "--theme-surface" => "rgba(136, 19, 55, 0.5)",
       "--theme-text" => "#ffe4e6",
       "--theme-text-secondary" => "#fecdd3"
     }, %{kind: :image, url: "/uploads/5/1/backgrounds/photo.webp"}},
    {"a gradient", @rhythm,
     %{color_scheme: "sunset", background_type: "gradient", background_value: "gradient_3"},
     %{
       "--theme-accent" => "#fbbf24",
       "--theme-accent-solid" => "#fbbf24",
       "--theme-background" => "linear-gradient(135deg, #FC466B 0%, #3F5EFB 100%)",
       "--theme-on-accent" => "#431407",
       "--theme-on-primary" => "#431407",
       "--theme-primary" => "#f97316",
       "--theme-primary-hover" => "#ea580c",
       "--theme-primary-solid" => "#f97316",
       "--theme-primary-solid-hover" => "#f35c0e",
       "--theme-secondary" => "#fb923c",
       "--theme-surface" => "rgba(92, 45, 10, 0.5)",
       "--theme-text" => "#fef3c7",
       "--theme-text-secondary" => "#fed7aa"
     }, %{kind: :gradient, css: "linear-gradient(135deg, #FC466B 0%, #3F5EFB 100%)"}},
    {"Rhythm with an uploaded video", @rhythm,
     %{
       color_scheme: "monochrome",
       background_type: "video",
       background_value: "custom",
       background_video_path: "7/2/backgrounds/clip.mp4"
     },
     %{
       "--theme-accent" => "#d1d5db",
       "--theme-accent-solid" => "#d1d5db",
       "--theme-background" => "#111827",
       "--theme-on-accent" => "#111827",
       "--theme-on-primary" => "#ffffff",
       "--theme-primary" => "#6b7280",
       "--theme-primary-hover" => "#4b5563",
       "--theme-primary-solid" => "#6b7280",
       "--theme-primary-solid-hover" => "#4b5563",
       "--theme-secondary" => "#9ca3af",
       "--theme-surface" => "rgba(31, 41, 55, 0.5)",
       "--theme-text" => "#f3f4f6",
       "--theme-text-secondary" => "#d1d5db"
     }, %{kind: :video, sources: @uploaded_video_sources, poster: nil}},
    {"Rhythm with its default video", @rhythm,
     %{
       color_scheme: "default",
       background_type: "video",
       background_value: "preset:rhythm-default"
     },
     %{
       "--theme-accent" => "#10b981",
       "--theme-accent-solid" => "#10b981",
       "--theme-background" => "#0f172a",
       "--theme-on-accent" => "#0f172a",
       "--theme-on-primary" => "#0f172a",
       "--theme-primary" => "#06b6d4",
       "--theme-primary-hover" => "#0891b2",
       "--theme-primary-solid" => "#06b6d4",
       "--theme-primary-solid-hover" => "#0891b2",
       "--theme-secondary" => "#14b8a6",
       "--theme-surface" => "rgba(30, 41, 59, 0.5)",
       "--theme-text" => "#e2e8f0",
       "--theme-text-secondary" => "#94a3b8"
     },
     %{
       kind: :video,
       sources: @rhythm_default_sources,
       poster: "/images/ui/posters/rhythm-background-poster.jpg"
     }}
  ]

  for {name, theme_id, columns, vars, background} <- @cases do
    test "a row with #{name} renders as the previous release rendered it" do
      profile = insert(:profile)
      roll_back_settings!()
      insert_legacy_row!(profile.id, unquote(theme_id), unquote(Macro.escape(columns)))
      MigrationRunner.up!(@settings_version)
      MigrationRunner.up!(@sync_version)

      assert_renders(
        profile.id,
        unquote(theme_id),
        unquote(Macro.escape(vars)),
        unquote(Macro.escape(background))
      )
    end
  end

  # The deploy window: the previous release, still serving after the
  # settings migration has run, inserts a row naming only its columns.
  test "a row the previous release inserts after the upgrade renders as it rendered it" do
    profile = insert(:profile)
    MigrationRunner.down!(@sync_version)

    insert_legacy_row!(profile.id, @quill, %{
      color_scheme: "purple",
      background_type: "gradient",
      background_value: "gradient_4"
    })

    MigrationRunner.up!(@sync_version)

    assert_renders(
      profile.id,
      @quill,
      %{
        "--theme-accent" => "#c084fc",
        "--theme-accent-solid" => "#c084fc",
        "--theme-background" => "linear-gradient(135deg, #11998e 0%, #38ef7d 100%)",
        "--theme-on-accent" => "#1e1b4b",
        "--theme-on-primary" => "#ffffff",
        "--theme-primary" => "#8b5cf6",
        "--theme-primary-hover" => "#7c3aed",
        "--theme-primary-solid" => "#8452f5",
        "--theme-primary-solid-hover" => "#7c3aed",
        "--theme-secondary" => "#a78bfa",
        "--theme-surface" => "rgba(46, 38, 84, 0.5)",
        "--theme-text" => "#ede9fe",
        "--theme-text-secondary" => "#c4b5fd"
      },
      %{kind: :gradient, css: "linear-gradient(135deg, #11998e 0%, #38ef7d 100%)"}
    )
  end

  defp assert_renders(profile_id, theme_id, vars, background) do
    customization = ThemeCustomizations.get_by_profile_and_theme(profile_id, theme_id)
    tokens = ThemeCustomizations.tokens(theme_id, customization)

    assert resolved_vars(tokens.vars) == vars
    assert tokens.dark_vars == %{}
    assert descriptor(tokens.media.background) == background
  end

  # `--theme-background` behind an image or a video names the canvas rather
  # than repeating its colour; resolve it, as the browser does.
  defp resolved_vars(%{"--theme-canvas" => canvas} = vars) do
    vars
    |> Map.delete("--theme-canvas")
    |> Map.new(fn
      {key, "var(--theme-canvas)"} -> {key, canvas}
      pair -> pair
    end)
  end

  defp descriptor(%{kind: :video, sources: sources} = descriptor),
    do: %{descriptor | sources: Enum.map(sources, &{&1.src, &1.type, &1.media})}

  defp descriptor(descriptor), do: descriptor

  # Both migrations off, so the table has the previous release's shape: the
  # columns and no `settings`.
  defp roll_back_settings! do
    MigrationRunner.down!(@sync_version)
    MigrationRunner.down!(@settings_version)
  end

  # The INSERT the previous release made: every option column, no `settings`.
  defp insert_legacy_row!(profile_id, theme_id, columns) do
    columns = Map.merge(@column_defaults, columns)
    {names, values} = Enum.unzip(columns)
    names = Enum.map_join(names, ", ", &Atom.to_string/1)
    params = Enum.map_join(1..length(values), ", ", &"$#{&1 + 2}")

    Repo.query!(
      """
      INSERT INTO theme_customizations (profile_id, theme_id, #{names}, inserted_at, updated_at)
      VALUES ($1, $2, #{params}, now(), now())
      """,
      [profile_id, theme_id | values]
    )
  end
end
