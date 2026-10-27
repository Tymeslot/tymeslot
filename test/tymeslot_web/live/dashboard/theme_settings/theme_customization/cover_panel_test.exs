defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CoverPanelTest do
  @moduledoc """
  The shared cover group through the dashboard, on the test-only showcase
  theme (`test/support/showcase_theme/`, id "97"): an organiser picks a
  preset cover or uploads one, choosing a preset deletes an uploaded cover,
  a cover and a logo upload each replace only their own file, and deleting
  the customisation deletes the logo, the cover and the background image.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  @theme_id "97"
  @covers ~w(elegant-still-life artistic-studio ocean-sunset rustic-farmhouse)

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @png MediaFixtures.png()

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    UploadRoot.isolate("tymeslot_cover")

    {:ok, ctx} = setup_dashboard_user_with_theme(%{conn: conn}, @theme_id)
    Map.new(ctx)
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")
    view
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

  defp upload_cover(view, name), do: upload(view, "#theme-cover-form", :cover_path, name)
  defp upload_logo(view, name), do: upload(view, "#theme-logo-form", :logo_path, name)

  defp cover_button(id),
    do:
      "[data-testid='cover-panel'] button[phx-click='theme:set_option']" <>
        "[phx-value-option='cover'][phx-value-field='cover_value'][phx-value-choice='#{id}']"

  defp saved(profile), do: ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id)

  defp served?(path), do: get(build_conn(), "/uploads/" <> path).status == 200

  test "offers the theme's covers, the default chosen until another is", %{conn: conn} do
    view = open(conn)

    assert Enum.reject(@covers, &has_element?(view, cover_button(&1))) == []
    refute has_element?(view, cover_button("space-satellite"))
    assert has_element?(view, cover_button("elegant-still-life") <> "[aria-pressed='true']")
    assert has_element?(view, "[data-testid='cover-panel'] #theme-cover-form")
    refute has_element?(view, "[data-testid='custom-cover']")
  end

  test "saves a preset cover through its button", %{conn: conn, profile: profile} do
    view = open(conn)

    view |> element(cover_button("ocean-sunset")) |> render_click()

    assert saved(profile).settings["cover_value"] == "ocean-sunset"
    assert has_element?(view, cover_button("ocean-sunset") <> "[aria-pressed='true']")
    assert has_element?(view, cover_button("elegant-still-life") <> "[aria-pressed='false']")
  end

  test "an uploaded cover becomes the custom cover", %{conn: conn, profile: profile} do
    view = open(conn)

    upload_cover(view, "cover.png")

    %{settings: settings} = saved(profile)
    assert settings["cover_value"] == "custom"
    assert settings["cover_path"] =~ ~r{^themes/#{profile.id}/97/images/}
    assert served?(settings["cover_path"])

    assert has_element?(
             view,
             "[data-testid='custom-cover-preview'][src='/uploads/#{settings["cover_path"]}']"
           )

    refute has_element?(view, "[data-testid='cover-panel'] button[aria-pressed='true']")
    assert render(view) =~ "Cover image uploaded successfully"
  end

  test "choosing a preset after an upload deletes the uploaded cover",
       %{conn: conn, profile: profile} do
    view = open(conn)
    upload_cover(view, "cover.png")
    uploaded = saved(profile).settings["cover_path"]

    view |> element(cover_button("artistic-studio")) |> render_click()

    %{settings: settings} = saved(profile)
    assert settings["cover_value"] == "artistic-studio"
    refute Map.has_key?(settings, "cover_path")
    refute served?(uploaded)
    refute has_element?(view, "[data-testid='custom-cover']")
  end

  test "a cover and a logo upload each replace only their own file",
       %{conn: conn, profile: profile} do
    view = open(conn)
    upload_logo(view, "logo.png")
    upload_cover(view, "first-cover.png")
    logo = saved(profile).settings["logo_path"]
    first_cover = saved(profile).settings["cover_path"]

    upload_cover(view, "second-cover.png")
    second_cover = saved(profile).settings["cover_path"]

    assert saved(profile).settings["logo_path"] == logo
    assert served?(logo)
    refute served?(first_cover)
    assert served?(second_cover)

    upload_logo(view, "new-logo.png")

    assert saved(profile).settings["cover_path"] == second_cover
    assert saved(profile).settings["cover_value"] == "custom"
    assert served?(second_cover)
    refute served?(logo)
  end
end
