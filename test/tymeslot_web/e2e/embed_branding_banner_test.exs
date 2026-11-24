defmodule TymeslotWeb.E2E.EmbedBrandingBannerTest do
  @moduledoc """
  The SaaS branding banner stays inside the viewport when the page content
  fits. Apart from `EmbedSizesMatrixTest` because it swaps the node-wide
  theme extensions, which every booking page then reads, so it runs alone.
  """
  use TymeslotWeb.BrowserCase, async: false

  import TymeslotWeb.E2E.BookerLayoutAssertions

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :scheduling

  # A viewport tall enough that the schedule comfortably fits — so the banner
  # only overflows if the `content-area` centering padding double-counts (the
  # bug). Below ~900px the schedule itself fills the viewport and the banner
  # legitimately sits below the fold, which wouldn't isolate the padding bug.
  @tag Playwright.Test.use(viewport: %{width: 1280, height: 1100})
  test "branding banner stays within the viewport when the page content fits",
       %{session: session} do
    # Inject a stand-in for the SaaS branding banner via the theme-extensions
    # bridge (Core can't load the SaaS branding CSS). The banner sits in the
    # theme grid's footer row; without the `:has(.branding-footer)` rule the
    # content area's 10vh centering padding pushes it past 100vh.
    previous = Application.get_env(:tymeslot, :theme_extensions, [])

    Application.put_env(:tymeslot, :theme_extensions, [
      {TymeslotWeb.Test.BrandingFooterStub, :banner}
    ])

    on_exit(fn -> Application.put_env(:tymeslot, :theme_extensions, previous) end)

    {profile, slug} = create_user_with_meeting_type()

    session
    |> visit("/#{profile.username}/#{slug}")
    |> assert_has(by_css(".branding-footer"))
    |> assert_no_horizontal_overflow("quill schedule with branding banner")
    |> assert_branding_footer_within_viewport("quill schedule with banner")
  end

  defp create_user_with_meeting_type do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Sizes Matrix Meeting",
        duration_minutes: 30,
        is_active: true
      })

    {profile, Slugs.to_slug(meeting_type)}
  end
end
