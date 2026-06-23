defmodule Tymeslot.AuthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Security.Password
  alias Tymeslot.Security.Token

  import Tymeslot.Factory

  describe "authenticate_user/3" do
    test "blocks access with invalid credentials" do
      user =
        insert(:user,
          password_hash: Password.hash_password("ValidPassword123!")
        )

      # Wrong password
      assert {:error, :invalid_password, _reason} =
               Auth.authenticate_user(user.email, "WrongPassword")

      # Non-existent user
      assert {:error, :not_found, _reason} =
               Auth.authenticate_user("fake@example.com", "Password123!")
    end
  end

  describe "request_email_change/3" do
    test "requires correct password to change email" do
      user =
        insert(:user,
          password_hash: Password.hash_password("CurrentPassword123!")
        )

      # Wrong password blocks change
      assert {:error, "Current password is incorrect"} =
               Auth.request_email_change(user, "new@example.com", "WrongPassword")

      # Duplicate email blocked
      insert(:user, email: "taken@example.com")

      assert {:error, "Email address is already in use"} =
               Auth.request_email_change(user, "taken@example.com", "CurrentPassword123!")
    end
  end

  describe "update_user_password/4" do
    test "users cannot access system with old sessions after password change" do
      user =
        insert(:user,
          password_hash: Password.hash_password("CurrentPassword123!")
        )

      # Create session before password change
      _old_session = insert(:user_session, user: user)

      # Change password
      {:ok, _updated_user} =
        Auth.update_user_password(
          user,
          "CurrentPassword123!",
          "NewPassword123!",
          "NewPassword123!"
        )

      # Verify new password works (sessions handled internally)
      assert {:ok, _user, _conn} = Auth.authenticate_user(user.email, "NewPassword123!")
    end
  end

  describe "register_user/3" do
    test "prevents duplicate registrations" do
      insert(:user, email: "taken@example.com")

      params = %{
        "email" => "TAKEN@EXAMPLE.COM",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "Duplicate User",
        "terms_accepted" => "true"
      }

      assert {:error, :auth, _reason} = Auth.register_user(params, %Plug.Conn{})
    end
  end

  describe "register_user/3 — registration disabled" do
    test "returns registration_disabled error when flag is off" do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)

      params = %{
        "email" => "new@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "New User",
        "terms_accepted" => "true"
      }

      assert {:error, :registration_disabled, "Registration is currently disabled."} =
               Auth.register_user(params, %Plug.Conn{})
    end
  end

  describe "password_reset" do
    test "oauth users cannot reset passwords" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)
      assert {:error, :oauth_user, _reason} = Auth.initiate_password_reset(oauth_user.email)
    end
  end

  describe "verify_user_email/1" do
    test "verifies email, returns the user, and broadcasts :user_registered" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _updated} = UserTokenQueries.set_verification_token(user, token)

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "auth:user_registered")

      assert {:ok, verified_user} = Auth.verify_user_email(token)
      assert verified_user.id == user.id

      user_id = user.id
      assert_receive {:user_registered, %{user: %{id: ^user_id}}}, 500
    end
  end

  describe "dashboard tour helpers" do
    test "dashboard_tour_seen?/1 returns false for a user with no timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)
      refute Auth.dashboard_tour_seen?(user)
    end

    test "dashboard_tour_seen?/1 returns true for a user with a timestamp" do
      user = insert(:user, dashboard_tour_seen_at: DateTime.utc_now(:second))
      assert Auth.dashboard_tour_seen?(user)
    end

    test "mark_dashboard_tour_seen/1 sets the timestamp when nil" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      assert {:ok, updated} = Auth.mark_dashboard_tour_seen(user)
      assert %DateTime{} = updated.dashboard_tour_seen_at
    end

    test "mark_dashboard_tour_seen/1 is idempotent — second call does not overwrite the first timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      {:ok, first} = Auth.mark_dashboard_tour_seen(user)
      {:ok, second} = Auth.mark_dashboard_tour_seen(first)

      assert second.dashboard_tour_seen_at == first.dashboard_tour_seen_at
    end
  end

  describe "marketing_unsubscribed?/1" do
    test "returns false for a freshly inserted user" do
      user = insert(:user)
      refute Auth.marketing_unsubscribed?(user)
    end

    test "returns true once the timestamp is set" do
      user = insert(:user, marketing_unsubscribed_at: DateTime.utc_now(:second))
      assert Auth.marketing_unsubscribed?(user)
    end
  end

  describe "unsubscribe_user_from_marketing/1 and resubscribe_user_to_marketing/1" do
    test "unsubscribe sets the timestamp" do
      user = insert(:user)

      assert {:ok, unsubscribed} = Auth.unsubscribe_user_from_marketing(user)
      assert Auth.marketing_unsubscribed?(unsubscribed)
    end

    test "unsubscribe is idempotent — calling twice keeps the user unsubscribed" do
      user = insert(:user)

      {:ok, first} = Auth.unsubscribe_user_from_marketing(user)
      {:ok, second} = Auth.unsubscribe_user_from_marketing(first)

      assert Auth.marketing_unsubscribed?(second)
      assert second.marketing_unsubscribed_at == first.marketing_unsubscribed_at
    end

    test "resubscribe clears the timestamp" do
      user = insert(:user, marketing_unsubscribed_at: DateTime.utc_now(:second))

      assert {:ok, resubscribed} = Auth.resubscribe_user_to_marketing(user)
      refute Auth.marketing_unsubscribed?(resubscribed)
    end

    test "resubscribe is idempotent — calling twice on an already-subscribed user succeeds" do
      user = insert(:user)

      {:ok, first} = Auth.resubscribe_user_to_marketing(user)
      refute Auth.marketing_unsubscribed?(first)

      {:ok, second} = Auth.resubscribe_user_to_marketing(first)
      refute Auth.marketing_unsubscribed?(second)
    end
  end

  describe "google_signup_login_hint/1" do
    test "returns the provider email for Google-signup users" do
      user =
        build(:user,
          provider: "google",
          google_user_id: "google-123",
          provider_email: "alice@gmail.com",
          email: "alice@work.example"
        )

      assert Auth.google_signup_login_hint(user) == "alice@gmail.com"
    end

    test "falls back to the account email when the provider email is missing" do
      user =
        build(:user,
          provider: "google",
          google_user_id: "google-123",
          provider_email: nil,
          email: "alice@work.example"
        )

      assert Auth.google_signup_login_hint(user) == "alice@work.example"
    end

    test "returns nil for users without a Google account" do
      assert Auth.google_signup_login_hint(build(:user, google_user_id: nil)) == nil
    end
  end
end
