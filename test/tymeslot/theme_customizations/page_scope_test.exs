defmodule Tymeslot.ThemeCustomizations.PageScopeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  setup do
    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)
    %{profile: profile, page: page}
  end

  test "the profile's row is found when a page row exists for the same theme", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "ocean")

    insert(:theme_customization,
      profile: ctx.profile,
      booking_page: ctx.page,
      theme_id: "1",
      color_scheme: "rose"
    )

    assert %{settings: %{"color_scheme" => "ocean"}} =
             ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1")

    assert %{settings: %{"color_scheme" => "rose"}} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")
  end

  test "a page's colours are found only through the profile that owns the page", ctx do
    insert(:theme_customization,
      profile: ctx.profile,
      booking_page: ctx.page,
      theme_id: "1",
      color_scheme: "rose"
    )

    other = insert(:profile)

    assert %{settings: %{"color_scheme" => "rose"}} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")

    assert ThemeCustomizations.get_by_profile_and_theme({other.id, ctx.page.id}, "1") == nil
  end

  test "an upsert in page scope writes the page's row and leaves the profile's alone", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "ocean")

    scope = {ctx.profile.id, ctx.page.id}

    {:ok, page_row} =
      ThemeCustomizations.apply_option(scope, "1", :palette, %{
        "field" => "scheme",
        "value" => "purple"
      })

    assert page_row.booking_page_id == ctx.page.id
    assert page_row.settings["color_scheme"] == "purple"

    assert %{settings: %{"color_scheme" => "ocean"}} =
             ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1")
  end

  test "a save in page scope updates the page's existing row, not the profile's", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1", color_scheme: "ocean")

    page_row =
      insert(:theme_customization,
        profile: ctx.profile,
        booking_page: ctx.page,
        theme_id: "1",
        color_scheme: "rose"
      )

    {:ok, saved} =
      ThemeCustomizations.apply_option({ctx.profile.id, ctx.page.id}, "1", :palette, %{
        "field" => "scheme",
        "value" => "purple"
      })

    assert saved.id == page_row.id
    assert saved.settings["color_scheme"] == "purple"
    assert length(Repo.all(ThemeCustomizationSchema)) == 2

    assert %{settings: %{"color_scheme" => "ocean"}} =
             ThemeCustomizations.get_by_profile_and_theme(ctx.profile.id, "1")
  end

  test "scope_for reads a page off an overlaid profile", ctx do
    assert ThemeCustomizations.scope_for(ctx.profile) == ctx.profile.id

    assert ThemeCustomizations.scope_for(%{ctx.profile | booking_page: ctx.page}) ==
             {ctx.profile.id, ctx.page.id}
  end

  test "copy_to_page copies colours and gradients but not uploaded backgrounds", ctx do
    insert(:theme_customization,
      profile: ctx.profile,
      theme_id: "1",
      color_scheme: "ocean",
      background_type: "gradient",
      background_value: "gradient_3"
    )

    insert(:theme_customization,
      profile: ctx.profile,
      theme_id: "2",
      color_scheme: "rose",
      background_type: "image",
      background_value: "custom",
      background_image_path: "1/2/uploaded.jpg"
    )

    assert :ok = ThemeCustomizations.copy_to_page(ctx.profile.id, ctx.page.id)

    quill = ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")
    rhythm = ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "2")

    assert %{
             "color_scheme" => "ocean",
             "background_type" => "gradient",
             "background_value" => "gradient_3"
           } = quill.settings

    # Rhythm's own default background stands in for the uploaded image.
    assert rhythm.settings["color_scheme"] == "rose"
    refute Map.has_key?(rhythm.settings, "background_image_path")

    assert {rhythm.settings["background_type"], rhythm.settings["background_value"]} ==
             {"video", "preset:rhythm-default"}
  end

  test "delete_page_customizations removes only the page's rows", ctx do
    insert(:theme_customization, profile: ctx.profile, theme_id: "1")
    insert(:theme_customization, profile: ctx.profile, booking_page: ctx.page, theme_id: "1")

    assert :ok = ThemeCustomizations.delete_page_customizations(ctx.page.id)

    assert [%{booking_page_id: nil}] = Repo.all(ThemeCustomizationSchema)
  end

  describe "uniqueness" do
    test "a second row for the same page and theme is not created", ctx do
      insert(:theme_customization, profile: ctx.profile, booking_page: ctx.page, theme_id: "1")

      assert {:ok, :exists} =
               ThemeCustomizationQueries.create(%{
                 "profile_id" => ctx.profile.id,
                 "booking_page_id" => ctx.page.id,
                 "theme_id" => "1",
                 "color_scheme" => "default",
                 "background_type" => "gradient",
                 "background_value" => "gradient_1"
               })

      assert length(Repo.all(ThemeCustomizationSchema)) == 1
    end

    test "a second profile-scope row for the same theme is still not created", ctx do
      insert(:theme_customization, profile: ctx.profile, theme_id: "1")

      assert {:ok, :exists} =
               ThemeCustomizationQueries.create(%{
                 "profile_id" => ctx.profile.id,
                 "theme_id" => "1",
                 "color_scheme" => "default",
                 "background_type" => "gradient",
                 "background_value" => "gradient_1"
               })

      assert length(Repo.all(ThemeCustomizationSchema)) == 1
    end

    test "a profile row and a page row for the same theme coexist", ctx do
      insert(:theme_customization, profile: ctx.profile, theme_id: "1")
      insert(:theme_customization, profile: ctx.profile, booking_page: ctx.page, theme_id: "1")

      assert length(Repo.all(ThemeCustomizationSchema)) == 2
    end
  end
end
