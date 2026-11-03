defmodule TymeslotWeb.Live.Scheduling.OwnerPreviewBrandingTest do
  @moduledoc """
  The page's owner previewing it (a verified preview token) is told the
  branding extension must stay away; a visitor's page leaves the decision to
  the extension.
  """

  # The extensions are global application config.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewMode

  defmodule BrandingProbe do
    @moduledoc false
    use Phoenix.Component

    @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
    def banner(assigns) do
      ~H"""
      <div id="branding-probe" data-show={inspect(@should_show_branding)} />
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

  defp probe(view) do
    [show] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("#branding-probe", "data-show")

    show
  end

  test "an owner preview tells the extension not to brand the page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, PreviewMode.owner_path("brandinghost", user.id))
    assert probe(view) == "false"
  end

  test "a visitor's page leaves branding to the extension", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/brandinghost")
    assert probe(view) == "nil"
  end
end
