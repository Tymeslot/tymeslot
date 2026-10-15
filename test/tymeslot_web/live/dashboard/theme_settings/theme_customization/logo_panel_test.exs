defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.LogoPanelTest do
  @moduledoc """
  The shared logo group through the dashboard, on the test-only showcase
  theme (`test/support/showcase_theme/`, id "97"), the registered theme that
  offers it: an organiser uploads a logo, replaces it and removes it, each
  change deleting the file it stops naming, and a logo upload leaves the
  background's upload alone. Deleting the customisation deletes every file.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  @theme_id "97"

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @png MediaFixtures.png()

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_logo_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    {:ok, ctx} = setup_dashboard_user_with_theme(%{conn: conn}, @theme_id)
    Map.new(ctx)
  end

  defp open(conn) do
    {:ok, view, html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")
    {view, html}
  end

  defp upload(view, form, field, name) do
    entry = %{
      last_modified: System.system_time(:millisecond),
      name: name,
      content: @png,
      type: "image/png"
    }

    view |> file_input(form, field, [entry]) |> render_upload(name)
    assert_push_event(view, "upload-complete", %{})
  end

  defp saved(profile), do: ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)

  defp stored?(path), do: File.exists?(Storage.build_theme_file_path(path))

  defp stored_file(profile, name) do
    path = "themes/#{profile.id}/#{@theme_id}/images/#{name}"
    absolute = Storage.build_theme_file_path(path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, @png)
    path
  end

  defp background_settings(customization),
    do:
      Map.take(
        customization.settings,
        ~w(background_type background_value background_image_path background_video_path)
      )

  test "offers the logo panel beside the theme's other groups, empty to begin with",
       %{conn: conn} do
    {view, html} = open(conn)

    assert has_element?(view, "[data-testid='logo-panel'] #theme-logo-form")
    assert has_element?(view, "[data-testid='logo-panel']", "No logo uploaded yet.")
    refute has_element?(view, "[data-testid='remove-logo']")
    assert html =~ "Colour Palette"
    assert html =~ "Background Design"
  end

  test "an uploaded logo is stored for the theme and shown in the panel",
       %{conn: conn, profile: profile} do
    {view, _html} = open(conn)

    upload(view, "#theme-logo-form", :logo_path, "logo.png")

    %{settings: settings} = saved(profile)
    assert settings["logo_path"] =~ ~r{^themes/#{profile.id}/97/images/}
    assert stored?(settings["logo_path"])

    assert settings["background_value"] ==
             ThemeCustomizations.get_defaults(@theme_id)["background_value"]

    assert has_element?(
             view,
             "[data-testid='logo-preview'][src='/uploads/#{settings["logo_path"]}']"
           )

    assert has_element?(view, "[data-testid='remove-logo']")
    assert render(view) =~ "Logo uploaded successfully"
  end

  test "a second logo replaces the first and deletes its file", %{conn: conn, profile: profile} do
    {view, _html} = open(conn)

    upload(view, "#theme-logo-form", :logo_path, "first.png")
    first = saved(profile).settings["logo_path"]

    upload(view, "#theme-logo-form", :logo_path, "second.png")
    second = saved(profile).settings["logo_path"]

    assert first != second
    refute stored?(first)
    assert stored?(second)
  end

  test "removing the logo deletes its file and empties the panel",
       %{conn: conn, profile: profile} do
    {view, _html} = open(conn)
    upload(view, "#theme-logo-form", :logo_path, "logo.png")
    path = saved(profile).settings["logo_path"]

    view |> element("[data-testid='remove-logo']") |> render_click()

    refute Map.has_key?(saved(profile).settings, "logo_path")
    refute stored?(path)
    assert has_element?(view, "[data-testid='logo-panel']", "No logo uploaded yet.")
    refute has_element?(view, "[data-testid='logo-preview']")
  end

  test "a logo upload leaves an uploaded background image and its file",
       %{conn: conn, profile: profile} do
    background = stored_file(profile, "a-background.png")

    {:ok, before} =
      ThemeCustomizations.create_theme_customization(profile.id, @theme_id, %{
        "color_scheme" => "neutral",
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => background
      })

    {view, _html} = open(conn)
    upload(view, "#theme-logo-form", :logo_path, "logo.png")

    after_upload = saved(profile)
    assert background_settings(after_upload) == background_settings(before)
    assert stored?(background)
    assert stored?(after_upload.settings["logo_path"])
  end

  test "deleting the customisation deletes the logo and the background image",
       %{conn: conn, profile: profile} do
    background = stored_file(profile, "a-background.png")

    {:ok, _before} =
      ThemeCustomizations.create_theme_customization(profile.id, @theme_id, %{
        "color_scheme" => "neutral",
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => background
      })

    {view, _html} = open(conn)
    upload(view, "#theme-logo-form", :logo_path, "logo.png")
    customization = saved(profile)
    logo = customization.settings["logo_path"]

    assert {:ok, _deleted} = ThemeCustomizations.delete_theme_customization(customization)

    refute stored?(logo)
    refute stored?(background)
  end
end
