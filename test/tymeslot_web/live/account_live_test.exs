defmodule TymeslotWeb.AccountLiveTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.TestFixtures
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.AccountLive.ErrorFormatter

  setup %{conn: conn} do
    RateLimiter.clear_all()
    user = create_user_fixture()
    # Ensure user is fully verified and onboarded
    {:ok, user} =
      user
      |> Changeset.change(%{
        verified_at: DateTime.utc_now(:second),
        onboarding_completed_at: DateTime.utc_now(:second)
      })
      |> Repo.update()

    # Get profile created by fixture
    profile = ProfileQueries.get_by_user_id(user.id)
    %{conn: log_in_user(conn, user), user: user, profile: profile}
  end

  describe "disconnected mount" do
    test "account page returns HTML before WebSocket upgrade", %{conn: conn} do
      conn = get(conn, ~p"/dashboard/account")
      assert html_response(conn, 200)

      {:ok, _view, _html} = live(conn)
    end
  end

  describe "Account Security Page" do
    test "renders account security page", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/account")

      assert html =~ "Account Security"
      assert html =~ "Email Address"
      assert html =~ "Password"
      assert html =~ user.email
    end

    test "toggles email form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert view |> element("button", "Change Email") |> render_click() =~ "New Email Address"
      assert view |> element("button", "Cancel") |> render_click() =~ "Change Email"
    end

    test "toggles password form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert view |> element("button", "Change Password") |> render_click() =~ "Current Password"
      assert view |> element("button", "Cancel") |> render_click() =~ "Change Password"
    end
  end

  describe "Email Changes" do
    test "updates email with valid data", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Email") |> render_click()

      new_email = "new-email@example.com"

      view
      |> form("form[phx-submit='update_email']", %{
        "email_form" => %{
          "new_email" => new_email,
          "current_password" => "Password123!"
        }
      })
      |> render_submit()

      assert render(view) =~ "Email Change Pending"
      assert render(view) =~ new_email

      # Verify user in DB
      updated_user = Repo.get(UserSchema, user.id)
      assert updated_user.pending_email == new_email
    end

    test "shows error for incorrect password on email change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Email") |> render_click()

      html =
        view
        |> form("form[phx-submit='update_email']", %{
          "email_form" => %{
            "new_email" => "valid@example.com",
            "current_password" => "WrongPassword123!"
          }
        })
        |> render_submit()

      assert html =~ "Current password is incorrect"
    end

    test "can cancel a pending email change", %{conn: conn, user: user} do
      # Setup pending email change
      {:ok, user, _email_change_token} =
        Auth.request_email_change(user, "pending@example.com", "Password123!")

      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert render(view) =~ "Email Change Pending"

      view |> element("button", "Cancel email change") |> render_click()

      refute render(view) =~ "Email Change Pending"

      updated_user = Repo.get(UserSchema, user.id)
      assert is_nil(updated_user.pending_email)
    end
  end

  describe "Password Changes" do
    test "redirects to login with explanatory flash on successful password change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      view
      |> form("form[phx-submit='update_password']", %{
        "password_form" => %{
          "current_password" => "Password123!",
          "new_password" => "NewPassword123!",
          "new_password_confirmation" => "NewPassword123!"
        }
      })
      |> render_submit()

      flash = assert_redirect(view, ~p"/auth/login")

      assert flash["info"] =~
               "Your password has been changed. Please sign in again with your new password."
    end

    test "shows error for password mismatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      html =
        view
        |> form("form[phx-submit='update_password']", %{
          "password_form" => %{
            "current_password" => "Password123!",
            "new_password" => "NewPassword123!",
            "new_password_confirmation" => "Mismatch123!"
          }
        })
        |> render_submit()

      assert html =~ "does not match"
    end

    test "shows error for short password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      html =
        view
        |> form("form[phx-submit='update_password']", %{
          "password_form" => %{
            "current_password" => "Password123!",
            "new_password" => "short",
            "new_password_confirmation" => "short"
          }
        })
        |> render_submit()

      assert html =~ "at least 8 characters"
    end

    test "shows error when new password is the same as current", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      html =
        view
        |> form("form[phx-submit='update_password']", %{
          "password_form" => %{
            "current_password" => "Password123!",
            "new_password" => "Password123!",
            "new_password_confirmation" => "Password123!"
          }
        })
        |> render_submit()

      assert html =~ "different from current"
    end
  end

  describe "Rate Limiting" do
    setup %{user: user} do
      # Exhaust the auth rate limit bucket (10 per 30 minutes) before each test
      Enum.each(1..10, fn _i ->
        RateLimiter.check_rate("login:#{user.email}", 1_800_000, 10)
      end)

      :ok
    end

    test "shows rate limit error when email change limit is exceeded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Email") |> render_click()

      view
      |> form("form[phx-submit='update_email']", %{
        "email_form" => %{
          "new_email" => "new@example.com",
          "current_password" => "Password123!"
        }
      })
      |> render_submit()

      # Flash is delivered via handle_info after the submit handler returns
      assert render(view) =~ "reached the limit"
    end

    test "shows rate limit error when password change limit is exceeded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      view
      |> form("form[phx-submit='update_password']", %{
        "password_form" => %{
          "current_password" => "Password123!",
          "new_password" => "NewPassword123!",
          "new_password_confirmation" => "NewPassword123!"
        }
      })
      |> render_submit()

      # Flash is delivered via handle_info after the submit handler returns
      assert render(view) =~ "reached the limit"
    end
  end

  describe "Social Login Users" do
    setup %{conn: conn} do
      user = insert(:user, provider: "google")
      {:ok, user} = Onboarding.mark_onboarding_complete(user)
      profile = insert(:profile, user: user)
      %{conn: log_in_user(conn, user), user: user, profile: profile}
    end

    test "cannot see change buttons for social accounts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # Buttons should be disabled
      assert render(view) =~ "disabled"
      assert render(view) =~ "Managed by Google"
    end

    test "cannot toggle forms or update for social users", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert render_click(view, "toggle_email_form") =~ "Account Security"
      refute render(view) =~ "New Email Address"

      assert render_click(view, "toggle_password_form") =~ "Account Security"
      refute render(view) =~ "Current Password"

      assert render_submit(view, "update_email", %{"email_form" => %{}}) =~ "Google"
      assert render_submit(view, "update_password", %{"password_form" => %{}}) =~ "Google"
    end
  end

  describe "Language Preference" do
    test "renders a language button per locale with Automatic active by default",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/account")

      assert html =~ ~s(phx-value-locale="de")
      assert html =~ "Automatic"
      assert html =~ "Deutsch"
      # The Automatic button carries a tooltip explaining what it does.
      assert html =~ "Follow your browser"
      # No saved locale → the Automatic button is the active selection.
      assert html =~ ~r/phx-value-locale=""[^>]*btn-tag-selector-primary--active/s
    end

    test "switching language persists it and re-renders the whole page in the new locale",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      {:ok, _view, html} =
        view
        |> element(~s(button[phx-value-locale="de"]))
        |> render_click()
        |> follow_redirect(conn)

      # Persisted immediately, no separate save step.
      assert Repo.get(UserSchema, user.id).locale == "de"

      # Confirmation flash renders in the newly selected language.
      assert html =~ "Spracheinstellung gespeichert"

      # The remount re-renders every string in German — including ones that
      # depend on no assign and would otherwise stay frozen by LiveView change
      # tracking: the card heading and the "Back to Dashboard" link.
      assert html =~ ~r/>Sprache</
      assert html =~ "Zurück zum Dashboard"

      # The German button is now the active selection.
      assert html =~ ~r/phx-value-locale="de"[^>]*btn-tag-selector-primary--active/s
    end

    test "switching to Automatic clears the persisted locale", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      {:ok, view, _html} =
        view
        |> element(~s(button[phx-value-locale="de"]))
        |> render_click()
        |> follow_redirect(conn)

      assert Repo.get(UserSchema, user.id).locale == "de"

      {:ok, _view, _html} =
        view
        |> element(~s(button[phx-value-locale=""]))
        |> render_click()
        |> follow_redirect(conn)

      assert Repo.get(UserSchema, user.id).locale == nil
    end
  end

  describe "Admin menu visibility" do
    setup do
      original = Application.get_env(:tymeslot, :enable_admin_ui)
      on_exit(fn -> Application.put_env(:tymeslot, :enable_admin_ui, original) end)
      :ok
    end

    test "shows Admin Settings to an admin when the admin UI is enabled",
         %{conn: conn, user: user} do
      Application.put_env(:tymeslot, :enable_admin_ui, true)
      {:ok, _admin} = user |> Changeset.change(%{is_admin: true}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert open_user_menu(view) =~ "Admin Settings"
    end

    test "hides Admin Settings from an admin when the admin UI is disabled",
         %{conn: conn, user: user} do
      Application.put_env(:tymeslot, :enable_admin_ui, false)
      {:ok, _admin} = user |> Changeset.change(%{is_admin: true}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # The route 404s when the admin UI is off, so the menu entry must not
      # dangle as a dead end.
      refute open_user_menu(view) =~ "Admin Settings"
    end

    test "hides Admin Settings from a non-admin user", %{conn: conn} do
      Application.put_env(:tymeslot, :enable_admin_ui, true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # Sanity check the menu is actually open, so the refute is meaningful.
      opened = open_user_menu(view)
      assert opened =~ "Sign Out"
      refute opened =~ "Admin Settings"
    end
  end

  describe "Miscellaneous Events" do
    test "validation events are no-ops that leave an open form open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # The validate hooks exist so early keystrokes do not trigger validation.
      # Opening a form and typing into it must therefore change nothing at all:
      # the form stays open and no error appears.
      assert render_click(view, "toggle_email_form") =~ "Cancel"
      assert render_click(view, "toggle_password_form") =~ "Cancel"
      opened = render(view)

      render_click(view, "validate_email_field", %{
        "email_form" => %{"email" => "not-an-email"}
      })

      render_click(view, "validate_password_field", %{
        "password_form" => %{"password" => "x"}
      })

      assert render(view) == opened
    end

    test "unknown events and messages change nothing and keep the view alive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")
      baseline = render(view)

      render_click(view, "unknown_event", %{})
      send(view.pid, :unknown_message)

      assert render(view) == baseline
      assert Process.alive?(view.pid)
    end
  end

  describe "Error Formatter" do
    test "formats various error types" do
      assert ErrorFormatter.format(:rate_limited) == %{
               base: ["Too many attempts. Please try again later."]
             }

      assert ErrorFormatter.format({:error, :rate_limited, "Rate limited"}) == %{
               base: ["Rate limited"]
             }

      assert ErrorFormatter.format({:error, "Current password is incorrect"}) == %{
               current_password: ["Current password is incorrect"]
             }

      assert ErrorFormatter.format({:error, "email already taken"}) == %{
               new_email: ["email already taken"]
             }

      assert ErrorFormatter.format({:error, "passwords must match"}) == %{
               new_password_confirmation: ["passwords must match"]
             }

      assert ErrorFormatter.format({:error, "must be at least 8 characters"}) == %{
               new_password: ["must be at least 8 characters"]
             }

      assert ErrorFormatter.format("some other error") == %{base: ["some other error"]}
      assert ErrorFormatter.format(%{field: "error"}) == %{field: ["error"]}
      assert ErrorFormatter.format(nil) == %{base: ["An unexpected error occurred"]}
    end
  end

  # The user dropdown renders its panel (Sign Out, Admin Settings, …) only while
  # open, so tests that assert on menu items must open it first.
  defp open_user_menu(view) do
    view
    |> element("#user-menu button[aria-haspopup='true']")
    |> render_click()
  end
end
