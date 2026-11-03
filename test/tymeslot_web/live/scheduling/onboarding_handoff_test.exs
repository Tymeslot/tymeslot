defmodule TymeslotWeb.Live.Scheduling.OnboardingHandoffTest do
  @moduledoc """
  The booking page tells the host's onboarding that it was opened from the
  handoff link (the live step's QR code), and only then: a valid owner
  token with `handoff=1`. The live step's own iframe carries a valid token
  without it, and a forged token never counts.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :onboarding
  @moduletag :scheduling

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory, only: [insert: 1]

  alias Tymeslot.Onboarding
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_calendar_mocks()

    %{user: user} = seed_booking_account("quill", "handoffhost", "Europe/London")
    :ok = Onboarding.subscribe(user.id)
    %{user: user}
  end

  test "a valid owner token with handoff=1 announces the opening", %{conn: conn, user: user} do
    {:ok, _view, _html} =
      live(conn, PreviewMode.owner_path("handoffhost", user.id, handoff: true))

    assert_receive {:onboarding, :preview_opened}
  end

  test "the stage's own preview, without handoff, announces nothing", %{conn: conn, user: user} do
    {:ok, _view, _html} = live(conn, PreviewMode.owner_path("handoffhost", user.id))

    refute_receive {:onboarding, :preview_opened}, 100
  end

  test "an invalid preview token never broadcasts", %{conn: conn} do
    other = insert(:user)

    for token <- ["forged", PreviewToken.sign(other.id)] do
      {:ok, _view, _html} =
        live(conn, "/handoffhost?preview=true&preview_token=#{token}&handoff=1")
    end

    refute_receive {:onboarding, :preview_opened}, 100
  end

  test "the static render announces nothing", %{conn: conn, user: user} do
    conn
    |> get(PreviewMode.owner_path("handoffhost", user.id, handoff: true))
    |> html_response(200)

    refute_receive {:onboarding, :preview_opened}, 100
  end
end
