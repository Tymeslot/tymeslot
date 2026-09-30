defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateMeetingExtrasTest do
  @moduledoc """
  What the host can give a quick-add meeting beyond a time and one guest: more
  guests, and the language all of them are written to. Driven through the form
  and the real creation task, so the row checked is the one the save produced.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(), locale: "de")
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # The host's dashboard is in German (`locale: "de"` above), so the reasons
  # a guest is refused are asserted as the host reads them.
  defp open_form(lv), do: hook(lv, "show_create_form", %{})

  defp hook(lv, event, params) do
    lv |> element("#calendar-grid") |> render_hook(event, params)
  end

  # Submitting the form the host types into, rather than handing the handler
  # the payload it expects.
  defp add_guest(lv, email) do
    lv |> form("#create-add-guest-form", %{"email" => email}) |> render_submit()
  end

  defp fill_guest(lv, email \\ "ada@example.com") do
    hook(lv, "update_create_guest_name", %{"value" => "Ada Lovelace"})
    hook(lv, "update_create_guest_email", %{"value" => email})
  end

  # Creation runs in a supervised task, so the row appears a moment after the
  # save event returns.
  defp save_and_fetch(lv) do
    hook(lv, "save_event", %{})
    eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)
  end

  defp guest_emails(meeting),
    do: meeting.id |> GuestQueries.list_for_meeting() |> Enum.map(& &1.email)

  describe "more guests" do
    test "invites everyone the host adds beside the main guest", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "One@Example.com")
      add_guest(lv, "two@example.com")

      meeting = save_and_fetch(lv)

      assert meeting.attendee_email == "ada@example.com"
      assert guest_emails(meeting) == ["one@example.com", "two@example.com"]
    end

    test "refuses the main guest's own address and repeats", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      refute add_guest(lv, "ada@example.com") =~ ~s(phx-value-email="ada@example.com")
      assert render(lv) =~ "ada@example.com ist bereits der Hauptgast."
      add_guest(lv, "one@example.com")
      add_guest(lv, "one@example.com")
      assert render(lv) =~ "one@example.com ist bereits eingeladen."

      assert guest_emails(save_and_fetch(lv)) == ["one@example.com"]
    end

    test "says why an invalid address was not added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      refute add_guest(lv, "not-an-email") =~ ~s(phx-value-email="not-an-email")
      assert render(lv) =~ "not-an-email ist keine gültige E-Mail-Adresse."
    end

    # The form used to accept anything shaped like an address, which the
    # booking then dropped without a word; it now asks the domain's rule.
    test "refuses an address the invitation itself would drop", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      refute add_guest(lv, "someone@example.invalidtld") =~
               ~s(phx-value-email="someone@example.invalidtld")

      assert render(lv) =~ "someone@example.invalidtld ist keine gültige E-Mail-Adresse."
    end

    test "invites an address typed into the field but never added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "one@example.com")

      lv
      |> element("#create-guest-email-input")
      |> render_change(%{"email" => " Two@Example.com "})

      assert guest_emails(save_and_fetch(lv)) == ["one@example.com", "two@example.com"]
    end

    test "an invalid address left in the field stops the save and says why", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      lv |> element("#create-guest-email-input") |> render_change(%{"email" => "two@"})
      hook(lv, "save_event", %{})

      assert render(lv) =~ "two@ ist keine gültige E-Mail-Adresse."
    end

    test "drops a guest who became the main guest after being added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "grace@example.com")
      add_guest(lv, "one@example.com")
      hook(lv, "update_create_guest_email", %{"value" => "Grace@example.com"})

      meeting = save_and_fetch(lv)

      assert meeting.attendee_email == "Grace@example.com"
      assert guest_emails(meeting) == ["one@example.com"]
    end

    test "a removed guest is not invited", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      add_guest(lv, "one@example.com")
      add_guest(lv, "two@example.com")
      hook(lv, "remove_create_guest", %{"email" => "one@example.com"})

      assert guest_emails(save_and_fetch(lv)) == ["two@example.com"]
    end

    test "stops offering the field once the cap is reached", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      for n <- 1..Guests.max_guests(), do: add_guest(lv, "guest#{n}@example.com")

      refute has_element?(lv, "#create-add-guest-form")

      # The one past the cap is not taken even if the event arrives anyway.
      hook(lv, "add_create_guest", %{"email" => "late@example.com"})

      assert length(guest_emails(save_and_fetch(lv))) == Guests.max_guests()
    end
  end

  describe "the language" do
    test "defaults to the host's own and is stored on the meeting", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      assert has_element?(
               lv,
               ~s(#create-meeting-locale button[phx-value-locale="de"][aria-pressed="true"])
             )

      assert save_and_fetch(lv).attendee_locale == "de"
    end

    test "follows the host's choice for this meeting", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      lv |> element(~s(#create-meeting-locale button[phx-value-locale="fr"])) |> render_click()

      assert save_and_fetch(lv).attendee_locale == "fr"
    end

    test "ignores a language the instance does not support", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      hook(lv, "update_create_locale", %{"locale" => "kl"})

      assert save_and_fetch(lv).attendee_locale == "de"
    end
  end
end
