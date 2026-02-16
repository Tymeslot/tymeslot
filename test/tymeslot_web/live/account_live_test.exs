defmodule TymeslotWeb.AccountLiveTest do
  use TymeslotWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Tymeslot.TestFixtures
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.UserSchema
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
      {:ok, user, _} = Auth.request_email_change(user, "pending@example.com", "Password123!")

      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      assert render(view) =~ "Email Change Pending"

      view |> element("button", "Cancel email change") |> render_click()

      refute render(view) =~ "Email Change Pending"

      updated_user = Repo.get(UserSchema, user.id)
      assert is_nil(updated_user.pending_email)
    end
  end

  describe "Password Changes" do
    test "updates password with valid data", %{conn: conn} do
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

      assert render(view) =~ "Password updated successfully"
      refute has_element?(view, "form[phx-submit='update_password']")
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
  end

  describe "Social Login Users" do
    setup %{conn: conn} do
      user = insert(:user, provider: "google")
      {:ok, user} = Auth.mark_onboarding_complete(user)
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

  describe "Miscellaneous Events" do
    test "ignores validation events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")
      assert render_click(view, "validate_email_field", %{}) =~ "Account Security"
      assert render_click(view, "validate_password_field", %{}) =~ "Account Security"
    end

    test "handles unknown messages and events gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # send unknown event
      assert render_click(view, "unknown_event", %{}) =~ "Account Security"

      # send unknown info message
      send(view.pid, :unknown_message)
      assert render(view) =~ "Account Security"
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
end
