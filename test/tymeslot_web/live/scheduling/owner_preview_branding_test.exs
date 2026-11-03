defmodule TymeslotWeb.Live.Scheduling.OwnerPreviewBrandingTest do
  @moduledoc """
  The page's owner previewing it (a verified preview token) is told the
  branding extension must stay away; a visitor's page leaves the decision to
  the extension. Every theme also tells the extensions whether the page is
  the owner's preview, so a page-view count can leave it out.
  """

  # The extensions are global application config.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory, only: [insert: 1, insert: 2]

  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.ThemeTestMatrix

  defmodule BrandingProbe do
    @moduledoc false
    use Phoenix.Component

    @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
    def banner(assigns) do
      ~H"""
      <div
        id="branding-probe"
        data-show={inspect(@should_show_branding)}
        data-owner-preview={inspect(@owner_preview)}
      />
      """
    end
  end

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_calendar_mocks()

    previous = Application.get_env(:tymeslot, :theme_extensions)
    Application.put_env(:tymeslot, :theme_extensions, [{BrandingProbe, :banner}])
    on_exit(fn -> Application.put_env(:tymeslot, :theme_extensions, previous) end)

    %{user: user} = seed_booking_account("quill", "brandinghost", "Europe/London")
    %{user: user}
  end

  defp probe(view, attribute \\ "data-show") do
    [value] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("#branding-probe", attribute)

    value
  end

  for theme <- ThemeTestMatrix.all() do
    test "#{theme.slug}: the extensions are told an owner preview from a visitor's view",
         %{conn: conn} do
      username = "ownerpreview#{unquote(theme.slug)}"
      %{user: user} = seed_booking_account(unquote(theme.id), username, "Europe/London")

      {:ok, preview, _html} = live(conn, PreviewMode.owner_path(username, user.id))
      assert probe(preview, "data-owner-preview") == "true"

      {:ok, visit, _html} = live(conn, "/" <> username)
      assert probe(visit, "data-owner-preview") == "false"
    end
  end

  test "an owner preview tells the extension not to brand the page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, PreviewMode.owner_path("brandinghost", user.id))
    assert probe(view) == "false"
  end

  test "a visitor's page leaves branding to the extension", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/brandinghost")
    assert probe(view) == "nil"
  end

  # The page an organiser without a bookable calendar shows instead of the
  # booking flow, as the onboarding stage frames it.
  describe "the page that cannot take bookings yet" do
    setup do
      user = insert(:user)
      insert(:profile, user: user, username: "nocalhost", timezone: "Etc/UTC")
      %{nocal_user: user}
    end

    test "an owner preview tells the extension not to brand it", %{conn: conn, nocal_user: user} do
      {:ok, view, _html} = live(conn, PreviewMode.owner_path("nocalhost", user.id, stage: true))

      assert has_element?(view, "[data-testid='readiness-notice']")
      assert probe(view) == "false"
    end

    test "a visitor's copy leaves branding to the extension", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/nocalhost")

      assert has_element?(view, "[data-testid='readiness-notice']")
      assert probe(view) == "nil"
    end

    test "another organiser's token is no owner preview", %{conn: conn, user: other} do
      path = PreviewMode.owner_path("nocalhost", other.id, stage: true)
      {:ok, view, _html} = live(conn, path)

      assert probe(view) == "nil"
    end
  end
end
