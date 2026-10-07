defmodule TymeslotWeb.ProfileIntroJourneyTest do
  @moduledoc """
  An organiser's headline and bio, written through `Profiles.update_intro/2`,
  as a visitor reads them on the booking page of a theme that introduces the
  organiser (the fixture theme's overview, the only one that renders them
  today): escaped, the bio's line breaks kept as paragraphs and `<br>`, null
  bytes gone, nothing over the caps ever stored, and a cleared field gone from
  the page.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :profiles
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @theme_id "99"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  setup do
    %{profile: profile} = seed_booking_account(@theme_id, "intro-organiser", "UTC")
    %{profile: profile}
  end

  # Always from the stored row, so a second save sees what the first wrote.
  defp save_intro(profile, intro), do: profile |> Repo.reload!() |> Profiles.update_intro(intro)

  # The visitor's view: a fresh, anonymous connection.
  defp booking_page(profile) do
    {:ok, page, _html} = live(build_conn(), ~p"/#{profile.username}")
    page
  end

  defp bio_paragraphs(page) do
    page
    |> element("[data-testid='fixture-overview'] [data-testid='profile-bio']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("p")
    |> Enum.map(fn paragraph ->
      {paragraph |> LazyHTML.text() |> String.split(),
       paragraph |> LazyHTML.query("br") |> Enum.count()}
    end)
  end

  describe "from Profiles.update_intro/2 to the booking page" do
    test "shows the headline, and the bio as paragraphs with its line breaks", %{profile: profile} do
      assert {:ok, _profile} =
               save_intro(profile, %{
                 "headline" => "Career coach for first-time managers",
                 "bio" => "I help new managers.\r\nOne call at a time.\r\n\r\nBook a slot below."
               })

      page = booking_page(profile)

      assert has_element?(
               page,
               "[data-testid='fixture-overview'] [data-testid='profile-headline']",
               "Career coach for first-time managers"
             )

      assert bio_paragraphs(page) == [
               {~w(I help new managers. One call at a time.), 1},
               {~w(Book a slot below.), 0}
             ]
    end

    test "escapes markup, so neither field can add elements to the page", %{profile: profile} do
      assert {:ok, _profile} =
               save_intro(profile, %{
                 "headline" => "<b>Coach</b> & mentor",
                 "bio" => ~s|<script>alert(1)</script>\n<a href="https://example.com">link</a>|
               })

      page = booking_page(profile)

      assert has_element?(page, "[data-testid='profile-headline']", "<b>Coach</b> & mentor")
      refute has_element?(page, "[data-testid='profile-headline'] b")
      refute has_element?(page, "[data-testid='profile-bio'] script")
      refute has_element?(page, "[data-testid='profile-bio'] a")
      assert render(page) =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "strips null bytes before they are stored", %{profile: profile} do
      assert {:ok, _profile} =
               save_intro(profile, %{"headline" => "Co\x00ach", "bio" => "Hello\x00 world"})

      stored = Repo.reload!(profile)
      assert {stored.headline, stored.bio} == {"Coach", "Hello world"}
      assert bio_paragraphs(booking_page(profile)) == [{~w(Hello world), 0}]
    end

    test "an over-long headline is refused and never reaches the page", %{profile: profile} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               save_intro(profile, %{
                 "headline" => String.duplicate("a", 121),
                 "bio" => "Held back too"
               })

      assert Keyword.has_key?(changeset.errors, :headline)
      assert {Repo.reload!(profile).headline, Repo.reload!(profile).bio} == {nil, nil}

      page = booking_page(profile)
      refute has_element?(page, "[data-testid='profile-headline']")
      refute has_element?(page, "[data-testid='profile-bio']")
    end

    test "an over-long bio is refused and never reaches the page", %{profile: profile} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               save_intro(profile, %{
                 "headline" => "Held back too",
                 "bio" => String.duplicate("a", 1001)
               })

      assert Keyword.has_key?(changeset.errors, :bio)
      assert {Repo.reload!(profile).headline, Repo.reload!(profile).bio} == {nil, nil}

      page = booking_page(profile)
      refute has_element?(page, "[data-testid='profile-headline']")
      refute has_element?(page, "[data-testid='profile-bio']")
    end

    test "fields exactly at their caps are stored and shown", %{profile: profile} do
      headline = String.duplicate("h", 120)
      bio = String.duplicate("b", 1000)

      assert {:ok, _profile} = save_intro(profile, %{"headline" => headline, "bio" => bio})

      page = booking_page(profile)
      assert has_element?(page, "[data-testid='profile-headline']", headline)
      assert has_element?(page, "[data-testid='profile-bio']", bio)
    end

    test "clearing both fields takes them off the page", %{profile: profile} do
      assert {:ok, _profile} = save_intro(profile, %{"headline" => "Coach", "bio" => "A bio"})
      assert {:ok, _profile} = save_intro(profile, %{"headline" => "", "bio" => "  \n "})

      stored = Repo.reload!(profile)
      assert {stored.headline, stored.bio} == {nil, nil}

      page = booking_page(profile)
      assert has_element?(page, "[data-testid='fixture-overview']")
      refute has_element?(page, "[data-testid='profile-headline']")
      refute has_element?(page, "[data-testid='profile-bio']")
    end
  end
end
