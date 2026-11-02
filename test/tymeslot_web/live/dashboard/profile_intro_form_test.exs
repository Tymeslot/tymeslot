defmodule TymeslotWeb.Dashboard.ProfileIntroFormTest do
  @moduledoc """
  The organiser's headline and bio, from the "About You" form in Profile
  Settings to Folio's booking page: saved with the button, shown as
  paragraphs and line breaks, escaped, cleaned of null bytes, refused over
  the caps, and gone again when cleared.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :profiles
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  setup %{conn: conn} do
    %{user: user, profile: profile} = seed_booking_account("4", "about-organiser", "UTC")

    user =
      user
      |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, profile: profile}
  end

  defp save_intro(conn, intro) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/settings")
    view |> form("#intro-form", profile_intro: intro) |> render_submit()
    view
  end

  defp booking_page(profile) do
    {:ok, page, html} = live(build_conn(), ~p"/#{profile.username}")
    {page, html}
  end

  defp stored(profile) do
    profile = Repo.reload!(profile)
    {profile.headline, profile.bio}
  end

  describe "from the form to Folio's overview" do
    test "a saved headline and bio show as paragraphs and line breaks", %{
      conn: conn,
      profile: profile
    } do
      view =
        save_intro(conn, %{
          headline: "Career coach for first-time managers",
          bio: "I help new managers.\nOne call at a time.\n\nBook a slot below."
        })

      assert render(view) =~ "Headline and bio saved"

      {page, _html} = booking_page(profile)

      assert has_element?(
               page,
               ".folio-masthead--full [data-testid='profile-headline']",
               "Career coach for first-time managers"
             )

      assert has_element?(page, "[data-testid='profile-bio'] p:first-child br")
      assert has_element?(page, "[data-testid='profile-bio'] p:last-child", "Book a slot below.")
    end

    test "markup is shown as text, never rendered", %{conn: conn, profile: profile} do
      save_intro(conn, %{headline: "<b>Coach</b>", bio: "<script>alert(1)</script>"})

      {_page, html} = booking_page(profile)

      assert html =~ "&lt;b&gt;Coach&lt;/b&gt;"
      refute html =~ "<b>Coach</b>"
      refute html =~ "<script>alert(1)</script>"
    end

    test "null bytes are stripped before saving", %{conn: conn, profile: profile} do
      save_intro(conn, %{headline: "Coach\u0000 for managers", bio: ""})

      assert stored(profile) == {"Coach for managers", nil}
    end

    test "an over-long headline is refused in the form and never stored", %{
      conn: conn,
      profile: profile
    } do
      view = save_intro(conn, %{headline: String.duplicate("a", 121), bio: "Fine."})

      assert has_element?(view, "#intro-form", "should be at most 120 character(s)")
      refute render(view) =~ "Headline and bio saved"
      assert stored(profile) == {nil, nil}
    end

    test "clearing both fields takes them off the page", %{conn: conn, profile: profile} do
      save_intro(conn, %{headline: "Coach", bio: "Hello."})
      assert stored(profile) == {"Coach", "Hello."}

      save_intro(conn, %{headline: "", bio: ""})

      assert stored(profile) == {nil, nil}

      {page, _html} = booking_page(profile)
      refute has_element?(page, "[data-testid='profile-headline']")
      refute has_element?(page, "[data-testid='profile-bio']")
    end
  end

  describe "the form" do
    test "sits in Profile Settings with both fields and the save button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      assert has_element?(view, "#intro-form-container", "About You")

      assert has_element?(
               view,
               "#intro-form input[name='profile_intro[headline]'][maxlength='120']"
             )

      assert has_element?(
               view,
               "#intro-form textarea[name='profile_intro[bio]'][maxlength='1000']"
             )

      assert has_element?(view, "#intro-form [data-testid='save-intro']")
    end

    test "flags an over-long bio while it is typed, and saves nothing", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#intro-form", profile_intro: %{headline: "", bio: String.duplicate("a", 1001)})
      |> render_change()

      assert has_element?(view, "#intro-form", "should be at most 1000 character(s)")
      assert Repo.reload!(profile).bio == nil
    end

    test "shows what is saved when the page is opened again", %{conn: conn} do
      save_intro(conn, %{headline: "Career coach", bio: "Line one\nLine two"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      assert has_element?(
               view,
               "#intro-form input[name='profile_intro[headline]'][value='Career coach']"
             )

      assert has_element?(view, "#intro-form textarea[name='profile_intro[bio]']", "Line one")
    end
  end
end
